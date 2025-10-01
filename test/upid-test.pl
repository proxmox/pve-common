#!/usr/bin/perl
#
package PVE::TestUPID;

# Basic tests for the UPID module

use v5.36;

use lib '../src';

use PVE::UPID;

use JSON qw(to_json);
use Test::More;

# Properties of a test:
#
# in - input string of the test
# out - expected output object of the test
# must_fail - if set to truthy the test must fail
my $test_upids = [
    {
        in => 'UPID:example-node:0000C346:165A0CE4:68D7279C:aptupdate::root@pam:',
        out => {
            id => '',
            node => 'example-node',
            pid => 49990,
            pstart => 375000292,
            starttime => 1758930844,
            type => 'aptupdate',
            user => 'root@pam',
        },
    },
    {
        in => 'UPID:example-node:000934AF:0D015579:68BF3A41:hastart:100:root@pam:',
        out => {
            id => '100',
            node => 'example-node',
            pid => 603311,
            pstart => 218191225,
            starttime => 1757362753,
            type => 'hastart',
            user => 'root@pam',
        },
    },
];

my $i = 0;
for my $test ($test_upids->@*) {
    $i++;
    my ($in, $out) = $test->@{ 'in', 'out' };

    my $test_name = "decode test case $i - input '$in'";
    my $task = eval {
        my $task = PVE::UPID::decode($in);
        is_deeply($task, $out, $test_name);
        return $task;
    };
    if (my $err = $@) {
        if ($test->{must_fail}) {
            pass("$test_name failed as expected");
        } else {
            diag($err);
            fail($test_name);
        }
    } elsif ($test->{must_fail}) {
        fail("$test_name was expected to fail, but passed");
    } else {
        my $task_as_json = to_json($task, { canonical => 1 });
        $test_name = "encode test case $i - input '$task_as_json'";
        my $upid = PVE::UPID::encode($task);
        is_deeply($upid, $in, $test_name);
    }
}

# TODO: other tests besides decode-encode cycle?

done_testing();
