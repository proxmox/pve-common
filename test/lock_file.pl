#!/usr/bin/perl

use lib '../src';
use strict;
use warnings;

use Socket;
use POSIX (); # don't import assert()

use PVE::Tools 'lock_file_full';

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
	return;
    };
    my $main = sub {
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

    PVE::Tools::run_fork($other, { afterfork => $main });
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
