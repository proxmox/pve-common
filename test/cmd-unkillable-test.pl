#!/usr/bin/perl

# run with a command that does not exit when killed, like one in uninterruptible sleep. Separate
# from cmd-test.pl, as it overrides kill for all code compiled after it, including PVE::Cmd.

use v5.36;

use lib '../src';

my $unkillable;

BEGIN {
    *CORE::GLOBAL::kill = sub($sig, @pids) {
        return scalar(@pids) if defined($unkillable) && grep { $_ == $unkillable } @pids;
        return CORE::kill($sig, @pids);
    };
}

use PVE::Cmd;

use POSIX ();
use Test::More;
use Time::HiRes ();

my @warned;
local $SIG{__WARN__} = sub { push @warned, @_ };

my $start = Time::HiRes::time();
eval {
    PVE::Cmd::run(
        ['sh', '-c', 'echo $$; exec sleep 30'],
        timeout => 1,
        outfunc => sub { $unkillable //= $_[0] },
    );
};
my $err = $@;
my $took = Time::HiRes::time() - $start;

like($err, qr/got timeout/, 'run reports its timeout');
like(join('', @warned), qr/did not exit after being killed/, 'run warns about the command');
ok($took < 15, sprintf("run does not wait for the command to exit (took %.1fs)", $took));
is(waitpid($unkillable, POSIX::WNOHANG), 0, 'run leaves the command behind');

my $pid = $unkillable;
$unkillable = undef;
kill(9, $pid);
waitpid($pid, 0);

done_testing();
