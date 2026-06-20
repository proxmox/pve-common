#!/usr/bin/perl
#
package PVE::TestCmd;

# Basic tests for the Cmd module

use v5.36;

use lib '../src';

use PVE::Cmd;

use Test::More;

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

# TODO:
# - cover pipe_socket (needs a socket peer)
# - cover timeouts and the errfunc/logfunc callbacks
# - more tests

done_testing();
