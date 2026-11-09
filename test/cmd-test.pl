#!/usr/bin/perl
#
package PVE::TestCmd;

# Basic tests for the Cmd module

use v5.36;

use lib '../src';

use PVE::Cmd;

use POSIX ();
use Test::More;
use Time::HiRes ();

# shell_quote: quote a single argument for the shell
#
# in  - input string
# out - expected quoted string
my $shell_quote_tests = [
    { in => 'plain', out => 'plain' },
    { in => 'with space', out => q{'with space'} },
    { in => 'a$b', out => q{'a$b'} },
    { in => '', out => q{''} },
];
for my $test ($shell_quote_tests->@*) {
    is(PVE::Cmd::shell_quote($test->{in}), $test->{out}, "shell_quote '$test->{in}'");
}

# to_string: turn a command (array of args) into a shell command line
is(PVE::Cmd::to_string(['echo', 'a b', 'c']), q{echo 'a b' c}, 'to_string quotes array args');
is(PVE::Cmd::to_string('already a string'), 'already a string',
    'to_string passes a string through');
eval { PVE::Cmd::to_string(undef) };
ok($@, 'to_string dies without arguments');

# split_args is the rough inverse of to_string, so a command survives the
# round-trip back into the same list of arguments
my $roundtrip_tests = [
    [qw(simple args here)], ['arg with spaces', 'second'], ['special $chars', 'a|b', 'c;d'],
];
for my $args ($roundtrip_tests->@*) {
    my $str = PVE::Cmd::to_string($args);
    is_deeply(PVE::Cmd::split_args($str), $args, "to_string/split_args round-trip '$str'");
}

is_deeply(PVE::Cmd::split_args(''), [], 'split_args on the empty string returns an empty list');
is_deeply(PVE::Cmd::split_args(q{a "b c" d}), ['a', 'b c', 'd'], 'split_args parses quoted words');

# run actually executes commands, smoke-test the common parameters
my $out = '';
my $rc = PVE::Cmd::run(['printf', 'first\nsecond\n'], outfunc => sub { $out .= "[$_[0]]" });
is($rc, 0, 'run returns the exit code zero on success');
is($out, '[first][second]', 'run feeds stdout to outfunc line by line');

my $upper = '';
PVE::Cmd::run(['tr', 'a-z', 'A-Z'], input => "hello\n", outfunc => sub { $upper .= $_[0] });
is($upper, 'HELLO', 'run passes input to the command stdin');

# an array of arrays is run as a shell pipe
my $piped = '';
PVE::Cmd::run([['printf', 'c\nb\na\n'], ['sort']], outfunc => sub { $piped .= $_[0] });
is($piped, 'abc', 'run runs an array of arrays as a pipe');

is(PVE::Cmd::run(['false'], noerr => 1), 1, 'run with noerr returns the non-zero exit code');
eval { PVE::Cmd::run(['false']) };
ok($@, 'run dies on a failing command without noerr');

is(PVE::Cmd::run_command(['true']), 0, 'run_command works as a wrapper for run');

# run must leave a pending alarm of its caller alone, like the time limit of a lock
#
# name  - how run is called
# cmd   - command to run, sleeps for a second by default
# param - parameters for run
my $caller_alarm_tests = [
    { name => 'without a timeout', param => {} },
    { name => 'with a timeout', param => { timeout => 5 } },
    {
        name => 'with a timeout on a command that cannot start',
        cmd => ['/nonexistent/command'],
        param => { timeout => 5 },
    },
];
for my $test ($caller_alarm_tests->@*) {
    my $fired;
    local $SIG{ALRM} = sub { $fired = Time::HiRes::time() };
    my $start = Time::HiRes::time();
    Time::HiRes::alarm(2);
    eval { PVE::Cmd::run($test->{cmd} // ['sleep', '1'], $test->{param}->%*) };
    Time::HiRes::sleep(0.1) until $fired || Time::HiRes::time() - $start > 5;
    Time::HiRes::alarm(0);
    ok($fired, "the caller's alarm still fires after run $test->{name}");
    my $after = defined($fired) ? $fired - $start : 99;
    cmp_ok($after, '<', 2.5, "run $test->{name} does not delay the caller's alarm");
}

# the flush of the last buffered stderr line must not replace the error that
# made run stop, even if the errfunc dies on it
{
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    eval {
        PVE::Cmd::run(
            ['sh', '-c', 'echo boomtrigger >&2; sleep 5'],
            timeout => 1,
            errmsg => 'msg',
            errfunc => sub { die "boom\n" if defined($_[0]) && $_[0] =~ /boomtrigger/ },
        );
    };
    like($@, qr/got timeout/, 'run reports its timeout, not a dying errfunc');
    like(join('', @warned), qr/boom/, 'run warns about the dying errfunc');
}

# run must not leave its command behind when it dies, whatever makes it die
#
# name  - when run dies
# param - parameters for run
# alarm - seconds until the caller's alarm handler dies
# err   - expected error
my $reap_tests = [
    { name => 'its own timeout fires', param => { timeout => 1 }, err => qr/got timeout/ },
    {
        name => 'outfunc dies',
        param => { outfunc => sub { die "outfunc failed\n" } },
        err => qr/outfunc failed/,
    },
    { name => "the caller's alarm handler dies", alarm => 1, err => qr/caller timed out/ },
];
for my $test ($reap_tests->@*) {
    my $pid;
    my %param = ($test->{param} // {})->%*;
    my $outfunc = delete($param{outfunc}) // sub { };
    eval {
        local $SIG{ALRM} = sub { die "caller timed out\n" };
        alarm($test->{alarm}) if $test->{alarm};
        PVE::Cmd::run(
            ['sh', '-c', 'echo $$; exec sleep 30'],
            outfunc => sub { $pid //= $_[0]; $outfunc->(@_) },
            %param,
        );
    };
    my $err = $@;
    alarm(0);
    like($err, $test->{err}, "run dies when $test->{name}");
    ok(
        waitpid($pid, POSIX::WNOHANG) == -1 && !kill(0, $pid),
        "run reaps the command when $test->{name}",
    );
}

# TODO:
# - cover pipe_socket (needs a socket peer)
# - cover the errfunc/logfunc callbacks
# - more tests

done_testing();
