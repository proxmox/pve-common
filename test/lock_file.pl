#!/usr/bin/perl

use lib '../src';
use strict;
use warnings;

use Socket;
use Fcntl qw(:flock);
use POSIX (); # don't import assert()

use PVE::Tools qw(lock_file_full try_lock_file);

my $name = "test.lockfile.$$-";

# Book-keeping:

my %_ran;

sub new {
    %_ran = ();
}

sub ran {
    my ($what) = @_;
    $_ran{$what} = 1;
}

sub assert {
    my ($what) = @_;
    die "code didn't run: $what\n" if !$_ran{$what};
}

sub assert_not {
    my ($what) = @_;
    die "code shouldn't have run: $what\n" if $_ran{$what};
}

# Does it actually lock? (shared=0)
# Can we get two simultaneous shared locks? (shared=1)
sub forktest1($) {
    my ($shared) = @_;
    new();
    # socket pair for synchronization
    socketpair(my $fmain, my $fother, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair(): $!\n";
    my $other = sub {
        # other side
        close($fmain);
        my $line;
        lock_file_full(
            $name,
            60,
            $shared,
            sub {
                ran('other side');
                # tell parent we've acquired the lock
                print {$fother} "1\n";
                $fother->flush();
                # wait for parent to be done trying to lock
                $line = <$fother>;
            },
        );
        die $@ if $@;
        die "parent failed\n" if !$line || $line ne "2\n";
        assert('other side');
        return;
    };
    my $main = sub {
        # main process
        # Wait for our child to lock:
        close($fother);
        my $line = <$fmain>;
        die "child failed to acquire a lock\n" if !$line || $line ne "1\n";
        lock_file_full(
            $name,
            1,
            $shared,
            sub {
                ran('local side');
            },
        );
        if ($shared) {
            assert('local side');
        } else {
            assert_not('local side');
        }
        print {$fmain} "2\n";
        $fmain->flush();
    };

    PVE::Tools::run_fork($other, { afterfork => $main });
    close($fmain);
}

# Does try_lock_file() leave a lock alone that another process holds, without waiting?
sub fork_try_lock_test() {
    new();
    socketpair(my $fmain, my $fother, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair(): $!\n";
    my $other = sub {
        close($fmain);
        my $line;
        lock_file_full(
            $name,
            60,
            0,
            sub {
                print {$fother} "1\n";
                $fother->flush();
                $line = <$fother>;
            },
        );
        die $@ if $@;
        die "parent failed\n" if !$line || $line ne "2\n";
        return;
    };
    my $main = sub {
        close($fother);
        my $line = <$fmain>;
        die "child failed to acquire a lock\n" if !$line || $line ne "1\n";
        my $start = time();
        my $locked = try_lock_file($name, sub { ran('try while held') });
        die "try_lock_file reports a lock that another process holds as taken\n" if $locked;
        die "try_lock_file waited for the lock\n" if time() - $start > 5;
        assert_not('try while held');
        print {$fmain} "2\n";
        $fmain->flush();
    };

    PVE::Tools::run_fork($other, { afterfork => $main });
    close($fmain);

    # the other process is done, so the lock is free again
    try_lock_file($name, sub { ran('try after release') }) or die "free lock is not taken\n";
    assert('try after release');
}

sub lock_is_free {
    open(my $fh, '>>', $name) or die "open(): $!\n";
    return flock($fh, LOCK_EX | LOCK_NB);
}

sub inherited_lock_test {
    my ($close_in_child, $try_lock) = @_;

    socketpair(my $fparent, my $fchild, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair(): $!\n";

    # both ways to take the lock report an error of the code in $@ here
    my $lock = sub {
        my ($code) = @_;
        return lock_file_full($name, 10, 0, $code) if !$try_lock;
        eval { try_lock_file($name, $code) or die "lock is not free\n" };
    };

    my $pid;
    $lock->(
        sub {
            $pid = fork() // die "fork(): $!\n";
            if (!$pid) {
                close($fparent);
                PVE::Tools::close_inherited_lock_handles() if $close_in_child;
                print {$fchild} "1\n";
                $fchild->flush();
                <$fchild>; # wait for parent to finish checks
                POSIX::_exit(0);
            }
            close($fchild);
            my $line = <$fparent>;
            die "child failed to start\n" if !$line || $line ne "1\n";
            die "lock released while the parent still holds it\n" if lock_is_free();
        },
    );

    my $err = $@;
    my $free = !$err && lock_is_free();
    print {$fparent} "2\n";
    $fparent->flush();
    waitpid($pid, 0) if $pid;
    close($fparent);
    die $err if $err;

    if ($close_in_child) {
        die "child kept the inherited lock held\n" if !$free;
    } else {
        die "child did not inherit the lock\n" if $free;
    }
}

eval {
    # Regular lock:
    new();
    lock_file_full($name, 10, 0, sub { ran('single lock') });
    assert('single lock');

    # Lock multiple times in a row:
    new();
    lock_file_full($name, 10, 0, sub { ran('lock A') });
    assert('lock A');
    lock_file_full($name, 10, 0, sub { ran('lock B') });
    assert('lock B');

    # Nested lock:
    new();
    lock_file_full(
        $name,
        10,
        0,
        sub {
            ran('lock A');
            lock_file_full($name, 10, 0, sub { ran('lock B') });
            assert('lock B');
            ran('lock C');
        },
    );
    assert('lock A');
    assert('lock B');
    assert('lock C');

    # Independent locks:
    new();
    lock_file_full(
        $name,
        10,
        0,
        sub {
            ran('lock A');
            # locks file "${name}2"
            lock_file_full($name . 2, 10, 0, sub { ran('lock B') });
            assert('lock B');
            ran('lock C');
        },
    );
    assert('lock A');
    assert('lock B');
    assert('lock C');

    # Does it actually lock? (shared=0)
    # Can we get two simultaneous shared locks? (shared=1)
    forktest1(0);
    forktest1(1);

    # Try-lock of a free lock, with the arguments passed on:
    new();
    my $locked = try_lock_file($name, sub { ran("try $_[0]") }, 'free');
    die "free lock is not reported as taken\n" if !$locked || $locked != 1;
    assert('try free');
    # ... which is released afterwards:
    lock_file_full($name, 1, 0, sub { ran('lock after try') });
    assert('lock after try');

    # Try-lock nested in a lock of this process, and the other way around:
    new();
    lock_file_full(
        $name,
        10,
        0,
        sub {
            try_lock_file($name, sub { ran('try in lock') }) or die "nested try-lock failed\n";
        },
    );
    die $@ if $@;
    assert('try in lock');
    try_lock_file(
        $name,
        sub {
            lock_file_full($name, 1, 0, sub { ran('lock in try') });
            die $@ if $@;
        },
    );
    assert('lock in try');

    # An error of the code is passed on, and the lock is released:
    eval {
        try_lock_file($name, sub { die "code failed\n" });
    };
    die "error of the code is not passed on: $@\n" if $@ ne "code failed\n";
    try_lock_file($name, sub { ran('try after error') }) or die "lock is not released\n";
    assert('try after error');

    fork_try_lock_test();

    # Lock held by child after parent released it?
    inherited_lock_test(0);
    # Lock free once child closed inherited copies?
    inherited_lock_test(1);
    # The same for a lock taken with try_lock_file():
    inherited_lock_test(0, 1);
    inherited_lock_test(1, 1);
};
my $err = $@;
system("rm $name*");
die $err if $err;
