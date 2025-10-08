#!/usr/bin/perl
#
package PVE::TestUPID;

# Basic tests for the UPID module

use v5.36;

use lib '../src';

use PVE::UPID;

use JSON qw(to_json);
use Test::MockModule;
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
    {
        # complex auth ID (long user name and API token)
        in => 'UPID:example-node:000934AF:0D015579:68BF3A41:vzdump:100:91a1da29-a47d-11f0-84e0-fafbfc944d00@pam!some-token:',
        out => {
            id => '100',
            node => 'example-node',
            pid => 603311,
            pstart => 218191225,
            starttime => 1757362753,
            type => 'vzdump',
            user => '91a1da29-a47d-11f0-84e0-fafbfc944d00@pam!some-token',
        },
    },
    {
        # test a 9-digit pstart (~ 20y uptime)
        in => 'UPID:example-node:000934AF:FFFFFFFFF:68BF3A41:fake-but-valid-type:100:root@pam:',
        out => {
            id => '100',
            node => 'example-node',
            pid => 603311,
            pstart => 68719476735,
            starttime => 1757362753,
            type => 'fake-but-valid-type',
            user => 'root@pam',
        },
    },
    {
        # UPID cannot contain spaces
        in => 'UPID:example-node:000934AF:0D015579:68BF3A41:broken type string:100:root@pam:',
        must_fail => 1,
    },
    {
        # some simple negative case to ensure we fail there.
        in => 'invalid garbage',
        must_fail => 1,
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


my $test_task_logs = {
    'task-ok' => {
        expected_status => 'OK',
        log => "Some log line\nTASK OK\n",
    },
    'task-err' => {
        expected_status => 'Some error message',
        log => "Some log line\nTASK ERROR: Some error message\n",
    },
    'task-unexpected-status' => {
        expected_status => 'unexpected status',
        log => "",
    },
    'task-warn' => {
        expected_status => 'WARNINGS: 42',
        log => "Some log line\nTASK WARNINGS: 42\n",
    },
};
my @test_task_log_names = sort keys $test_task_logs->%*;

# prepare test data to make using them easier
$test_task_logs->{$_}->{upid} = "UPID:example-node:0000C346:165A0CE4:68D7279C:${_}::root\@pam:"
    for keys $test_task_logs->%*;

my $task_log_filesystem = {
    map { ("/var/log/pve/tasks/C/$test_task_logs->{$_}->{upid}" => $test_task_logs->{$_}) } @test_task_log_names
};

my $mock_pve_file = Test::MockModule->new("PVE::File")->redefine(
    'file_read_last_line' => sub($filename) {
        die "file '$filename' not found" if !$task_log_filesystem->{$filename};

        my $file_content = $task_log_filesystem->{$filename}->{log};

        return $file_content if $file_content !~ m/\n?(.+)$/;

        return $1;
    },
);

for my $task_log (sort keys $test_task_logs->%*) {
    my $task = $test_task_logs->{$task_log};

    my $status = PVE::UPID::read_status($task->{upid});

    is_deeply($status, $task->{expected_status}, "task log test '$task_log'");
}

# TODO: other tests besides decode-encode cycle?

done_testing();
