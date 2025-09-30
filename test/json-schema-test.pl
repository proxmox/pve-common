#!/usr/bin/perl
#
package PVE::TestJSONSchema;

# Basic tests for the behavior of the JSON schema, like property string parsing and serializing.

use strict;
use warnings;

use lib '../src';

use PVE::JSONSchema qw(parse_property_string);

use Test::More;

# Properties of a test:
#
# name - describes the test, should normally be < 100 characters to keep build output somewhat clean
# format - the format as passed to parse_property_string.
# out - the default output, useful for multiple sub-test that should result in the same data.
# subtests - object with:
#   in - input of the sub-test
#   out - expected output of the sub-test, falls back to outer `out`
#   must_fail - if set the test must fail and the error must match the regex defined here.
my $property_string_tests = [
    {
        name => 'default-key-with-type-boolean',
        format => {
            enabled => {
                type => 'boolean',
                default_key => 1,
            },
        },
        out => { enabled => 1 },
        subtests => [
            { in => "1" },
            { in => "true" },
            { in => "yes" },
            { in => "on" },
            { in => "enabled=1" },
            { in => "enabled=true" },
            { in => "enabled=yes" },
            { in => "enabled=on" },
            { in => "enabled=wrong", must_fail => qr/type check \('boolean'\) failed/ },
            { in => "wrong", must_fail => qr/type check \('boolean'\) failed/ },
        ],
    },
    {
        name => 'no-default-key-with-type-boolean',
        format => {
            enabled => {
                type => 'boolean',
            },
        },
        out => { enabled => 1 },
        subtests => [
            { in => "1", must_fail => qr/value without key, but schema does not define a default key/ },
            { in => "true", must_fail => qr/value without key, but schema does not define a default key/ },
            { in => "yes", must_fail => qr/value without key, but schema does not define a default key/ },
            { in => "on", must_fail => qr/value without key, but schema does not define a default key/ },
            { in => "enabled=1" },
            { in => "enabled=true" },
            { in => "enabled=yes" },
            { in => "enabled=on" },
        ],
    },
    # TODO: more tests, like complex formats and ranges and the like
];

for my $test ($property_string_tests->@*) {
    my $subtests = $test->{subtests} // [ { in => $test->{in}, out => $test->{out} } ];

    subtest $test->{name}, sub {
        my $i = 0;
        for my $subtest ($subtests->@*) {
            $i++;
            my $subtest_name = ($subtest->{name} // '') . " input '$subtest->{in}'";
            eval {
                my $res = parse_property_string($test->{format}, $subtest->{in});
                is_deeply($res, $subtest->{out} // $test->{out}, $subtest_name);
            };
            if (my $err = $@) {
                if ($subtest->{must_fail} && $err =~ $subtest->{must_fail}) {
                    pass("$subtest_name failed as expected");
                } else {
                    diag($err);
                    fail($subtest_name);
                }
            } elsif ($subtest->{must_fail}) {
                fail("$subtest_name was expected to fail, but passed");
            }
        }
        done_testing();
    }
}

# TODO: other tests besides parse property?

done_testing();
