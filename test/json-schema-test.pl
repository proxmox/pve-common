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
            {
                in => "1",
                must_fail => qr/value without key, but schema does not define a default key/,
            },
            {
                in => "true",
                must_fail => qr/value without key, but schema does not define a default key/,
            },
            {
                in => "yes",
                must_fail => qr/value without key, but schema does not define a default key/,
            },
            {
                in => "on",
                must_fail => qr/value without key, but schema does not define a default key/,
            },
            { in => "enabled=1" },
            { in => "enabled=true" },
            { in => "enabled=yes" },
            { in => "enabled=on" },
        ],
    },
    {
        name => 'alias-in-property-str',
        format => {
            enabled => {
                type => 'boolean',
                default_key => 1,
            },
            active => { alias => 'enabled' },
        },
        out => { enabled => 1 },
        subtests => [
            { in => "1" },
            { in => "active=1" },
            { in => "active=true" },
            { in => "active=yes" },
            { in => "active=on" },
            { in => "active=wrong", must_fail => qr/type check \('boolean'\) failed/ },
        ],
    },
    # TODO: more tests, like complex formats and ranges and the like
];

for my $test ($property_string_tests->@*) {
    my $subtests = $test->{subtests} // [{ in => $test->{in}, out => $test->{out} }];

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

# check_object alias tests
#
# Properties of a test:
#
# name - describes the test
# schema - the object schema passed to check_object
# subtests - list of:
#   in - input hash (will be cloned to avoid mutation across subtests)
#   out - expected hash after alias remapping (undef to skip check)
#   must_fail - regex that must match the error string
my $check_object_alias_tests = [
    {
        name => 'alias-remapping',
        schema => {
            'old-name' => { alias => 'new-name' },
            'new-name' => { type => 'integer', optional => 1 },
        },
        subtests => [
            {
                name => 'alias key is remapped to target',
                in => { 'old-name' => 5 },
                out => { 'new-name' => 5 },
            },
            {
                name => 'target key is not touched',
                in => { 'new-name' => 3 },
                out => { 'new-name' => 3 },
            },
            {
                name => 'both alias and target is rejected',
                in => { 'old-name' => 5, 'new-name' => 3 },
                must_fail => qr/cannot set both/,
            },
            {
                name => 'alias is implicitly optional',
                in => {},
                out => {},
            },
        ],
    },
    {
        name => 'alias-validated-against-target-schema',
        schema => {
            'old-name' => { alias => 'new-name' },
            'new-name' => { type => 'integer', optional => 1, minimum => 1, maximum => 10 },
        },
        subtests => [
            {
                name => 'valid value passes target schema',
                in => { 'old-name' => 5 },
                out => { 'new-name' => 5 },
            },
            {
                name => 'out-of-range value is rejected by target schema',
                in => { 'old-name' => 999 },
                must_fail => qr/maximum value/,
            },
        ],
    },
];

for my $test ($check_object_alias_tests->@*) {
    subtest $test->{name}, sub {
        for my $subtest ($test->{subtests}->@*) {
            my $name = $subtest->{name} // 'unnamed';
            my $value = { $subtest->{in}->%* }; # shallow clone

            my $errors = {};
            PVE::JSONSchema::check_object('test', $test->{schema}, $value, 0, $errors);
            my $err_str = join("\n", map { "$_: $errors->{$_}" } sort keys %$errors);

            if ($subtest->{must_fail}) {
                like($err_str, $subtest->{must_fail}, "$name - failed as expected");
            } else {
                is($err_str, '', "$name - no errors");
                is_deeply($value, $subtest->{out}, "$name - value remapped correctly")
                    if $subtest->{out};
            }
        }
        done_testing();
    };
}

done_testing();
