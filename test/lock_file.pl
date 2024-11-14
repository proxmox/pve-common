#!/usr/bin/perl

use lib '../src';
use strict;
use warnings;

use Socket;
use POSIX (); # don't import assert()

use PVE::Tools 'lock_file_full';

my $name = "test.lockfile.$$-";

# Utilities:

sub forked($$) {
    my ($code1, $code2) = @_;

    pipe(my $except_r, my $except_w) or die "pipe: $!\n";

    my $pid = fork();
    die "fork failed: $!\n" if !defined($pid);

    if ($pid == 0) {
	close($except_r);
	eval { $code1->() };
	if ($@) {
	    print {$except_w} $@;
	    $except_w->flush();
	    POSIX::_exit(1);
	}
	POSIX::_exit(0);
    }
    close($except_w);

    eval { $code2->() };
    my $err = $@;
    if ($err) {
	kill(15, $pid);
    } else {
	my $err = do { local $/ = undef; <$except_r> };
    }
    die "interrupted\n" if waitpid($pid, 0) != $pid;
    die $err if $err;

    # Check exit code:
    my $status = POSIX::WEXITSTATUS($?);
    if ($? == -1) {
	die "failed to execute\n";
    } elsif (POSIX::WIFSIGNALED($?)) {
	my $sig = POSIX::WTERMSIG($?);
	die "got signal $sig\n";
    } elsif ($status != 0) {
	die "exit code $status\n";
    }
}

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
    forked sub {
	    # other side
	    close($fmain);
	    my $line;
	    lock_file_full($name, 60, $shared, sub {
		ran('other side');
		# tell parent we've acquired the lock
		print {$fother} "1\n";
		$fother->flush();
		# wait for parent to be done trying to lock
		$line = <$fother>;
	    });
	    die $@ if $@;
	    die "parent failed\n" if !$line || $line ne "2\n";
	    assert('other side');
    }, sub {
	    # main process
	    # Wait for our child to lock:
	    close($fother);
	    my $line = <$fmain>;
	    die "child failed to acquire a lock\n" if !$line || $line ne "1\n";
	    lock_file_full($name, 1, $shared, sub {
		ran('local side');
	    });
	    if ($shared) {
		assert('local side');
	    } else {
		assert_not('local side');
	    }
	    print {$fmain} "2\n";
	    $fmain->flush();
    };
    close($fmain);
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
    lock_file_full($name, 10, 0, sub {
	ran('lock A');
	lock_file_full($name, 10, 0, sub { ran('lock B') });
	assert('lock B');
	ran('lock C');
    });
    assert('lock A');
    assert('lock B');
    assert('lock C');

    # Independent locks:
    new();
    lock_file_full($name, 10, 0, sub {
	ran('lock A');
	# locks file "${name}2"
	lock_file_full($name.2, 10, 0, sub { ran('lock B') });
	assert('lock B');
	ran('lock C');
    });
    assert('lock A');
    assert('lock B');
    assert('lock C');

    # Does it actually lock? (shared=0)
    # Can we get two simultaneous shared locks? (shared=1)
    forktest1(0);
    forktest1(1);
};
my $err = $@;
system("rm $name*");
die $err if $err;
