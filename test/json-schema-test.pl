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
            {
                in => "enabled=1,active=1",
                must_fail => qr/already defined \(via alias\)/,
            },
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

# check allOf schemas
my $check_all_of = [
    {
        name => 'simple all of',
        schema => {
            allOf => [
                {
                    additionalProperties => 0,
                    properties => {
                        first => {
                            type => 'string',
                        },
                        'opt-first' => {
                            type => 'string',
                            optional => 1,
                        },
                    },
                },
                {
                    additionalProperties => 0,
                    properties => {
                        second => {
                            type => 'string',
                        },
                        'opt-second' => {
                            type => 'string',
                            optional => 1,
                        },
                    },
                },
            ],
        },
        subtests => [
            {
                name => 'mandatory properties',
                in => {
                    first => 'hello',
                    second => 'hello',
                },
            },
            {
                name => 'optional properties',
                in => {
                    first => 'hello',
                    'opt-first' => 'hello',
                    second => 'hello',
                    'opt-second' => 'hello',
                },
            },
            {
                name => 'missing properties',
                in => {
                    first => 'hello',
                },
                must_fail => qr/^second: property is missing and it is not optional/,
            },
            {
                name => 'neither allow additional properties',
                in => {
                    first => 'hello',
                    second => 'hello',
                    'bad-property' => 1,
                },
                must_fail => qr/^bad-property: property is not defined in schema and/,
            },
        ],
    },
    {
        name => 'one has additional properties',
        schema => {
            allOf => [
                {
                    additionalProperties => 0,
                    properties => {
                        first => {
                            type => 'string',
                        },
                        'opt-first' => {
                            type => 'string',
                            optional => 1,
                        },
                    },
                },
                {
                    additionalProperties => 1,
                    properties => {
                        second => {
                            type => 'string',
                        },
                        'opt-second' => {
                            type => 'string',
                            optional => 1,
                        },
                    },
                },
            ],
        },
        subtests => [
            {
                name => 'mandatory properties',
                in => {
                    first => 'hello',
                    second => 'hello',
                },
            },
            {
                name => 'optional properties',
                in => {
                    first => 'hello',
                    'opt-first' => 'hello',
                    second => 'hello',
                    'opt-second' => 'hello',
                },
            },
            {
                name => 'missing properties',
                in => {
                    second => 'hello',
                },
                must_fail => qr/^first: property is missing and it is not optional/,
            },
            {
                name => 'additional properties work',
                in => {
                    first => 'hello',
                    second => 'hello',
                    'valid-additional-property' => 1,
                },
            },
        ],
    },
    {
        name => 'nested allOf error handling',
        schema => {
            allOf => [
                {
                    additionalProperties => 0,
                    properties => {
                        first => {
                            type => 'string',
                        },
                        'opt-first' => {
                            type => 'string',
                            optional => 1,
                        },
                    },
                },
                {
                    allOf => [
                        {
                            additionalProperties => 0,
                            properties => {
                                second => {
                                    type => 'string',
                                },
                                'opt-second' => {
                                    type => 'string',
                                    optional => 1,
                                },
                            },
                        },
                        {
                            additionalProperties => 0,
                            properties => {
                                third => {
                                    type => 'string',
                                },
                                'opt-third' => {
                                    type => 'string',
                                    optional => 1,
                                },
                            },
                        },
                    ],
                },
            ],
        },
        subtests => [
            {
                name => 'mandatory properties',
                in => {
                    first => 'hello',
                    second => 'hello',
                    third => 'hello',
                },
            },
            {
                name => 'optional properties',
                in => {
                    first => 'hello',
                    'opt-first' => 'hello',
                    second => 'hello',
                    'opt-second' => 'hello',
                    third => 'hello',
                    'opt-third' => 'hello',
                },
            },
            {
                name => 'missing properties from nested',
                in => {
                    first => 'hello',
                    second => 'hello',
                },
                must_fail => qr/^third: property is missing and it is not optional/,
            },
            {
                name => 'missing properties top level',
                in => {
                    second => 'hello',
                    third => 'hello',
                },
                must_fail => qr/^first: property is missing and it is not optional/,
            },
            {
                name => 'none allow additional properties',
                in => {
                    first => 'hello',
                    second => 'hello',
                    third => 'hello',
                    'bad-property' => 1,
                },
                must_fail => qr/^bad-property: property is not defined in schema and/,
            },
        ],
    },
];

for my $test ($check_all_of->@*) {
    subtest $test->{name}, sub {
        for my $subtest ($test->{subtests}->@*) {
            my $name = $subtest->{name} // 'unnamed';
            my $value = { $subtest->{in}->%* }; # shallow clone

            my $errors = {};
            PVE::JSONSchema::check_prop($value, $test->{schema}, undef, $errors);
            my $err_str = join("\n", map { "$_: $errors->{$_}" } sort keys %$errors);

            if ($subtest->{must_fail}) {
                like($err_str, $subtest->{must_fail}, "$name - failed as expected");
            } else {
                is($err_str, '', "$name - no errors");
            }
        }
        done_testing();
    };
}
#
# check oneOf schemas
my $check_one_of = [
    {
        name => 'simple one-of',
        schema => {
            'type-property' => 'type',
            'type-property-schema' => {
                type => 'string',
                enum => ['one', 'two'],
            },
            oneOf => [
                {
                    'instance-type' => 'one',
                    additionalProperties => 0,
                    properties => {
                        first => {
                            type => 'string',
                        },
                        'opt-first' => {
                            type => 'string',
                            optional => 1,
                        },
                    },
                },
                {
                    'instance-type' => 'two',
                    additionalProperties => 0,
                    properties => {
                        second => {
                            type => 'string',
                        },
                        'opt-second' => {
                            type => 'string',
                            optional => 1,
                        },
                    },
                },
            ],
        },
        subtests => [
            {
                name => 'missing type',
                in => {
                    first => 'hello',
                },
                # The missing type makes the rest of the values unknown.
                must_fail => {
                    'type' => qr/^property is missing /,
                    'first' => qr/^property is not defined /,
                },
            },
            {
                name => 'explicit null type',
                in => {
                    type => undef,
                    first => 'hello',
                },
                # A null type behaves like a missing one: it is reported as missing rather
                # than as an unknown property, the rest of the values become unknown.
                must_fail => {
                    'type' => qr/^property is missing /,
                    'first' => qr/^property is not defined /,
                },
            },
            {
                name => 'mandatory properties 1',
                in => {
                    type => 'one',
                    first => 'hello',
                },
            },
            {
                name => 'mandatory properties 2',
                in => {
                    type => 'two',
                    second => 'hello',
                },
            },
            {
                name => 'wrong type 1',
                in => {
                    type => 'one',
                    second => 'hello',
                },
                must_fail => {
                    'oneOf[one].first' => qr/^property is missing /,
                    'oneOf[one].second' => qr/^property is not defined /,
                },
            },
            {
                name => 'wrong type 2',
                in => {
                    type => 'two',
                    first => 'hello',
                },
                must_fail => {
                    'oneOf[two].first' => qr/^property is not defined /,
                    'oneOf[two].second' => qr/^property is missing /,
                },
            },
        ],
    },
    {
        name => 'nesting allOf->oneOf->allOf->oneOf',
        schema => {
            allOf => [
                {
                    additionalProperties => 0,
                    properties => {
                        first => {
                            type => 'string',
                        },
                    },
                },
                {
                    'type-property' => 'type',
                    'type-property-schema' => {
                        type => 'string',
                        enum => [qw(one two)],
                    },
                    oneOf => [
                        {
                            'instance-type' => 'one',
                            additionalProperties => 0,
                            properties => {
                                'one-a' => {
                                    type => 'string',
                                },
                                'one-b' => {
                                    type => 'number',
                                },
                            },
                        },
                        {
                            'instance-type' => 'two',
                            allOf => [
                                {
                                    additionalProperties => 0,
                                    properties => {
                                        'two-a' => {
                                            type => 'number',
                                        },
                                    },
                                },
                                {
                                    additionalProperties => 0,
                                    properties => {
                                        'two-b' => {
                                            type => 'string',
                                        },
                                    },
                                },
                                {
                                    'type-property' => 'inner-type',
                                    'type-property-schema' => {
                                        type => 'string',
                                        enum => [qw(inner-a inner-b)],
                                    },
                                    optional => 1,
                                    oneOf => [
                                        {
                                            'instance-type' => 'inner-a',
                                            additionalProperties => 0,
                                            properties => {
                                                'inner-a-elem' => {
                                                    type => 'string',
                                                    enum => ['correct', 'correct2'],
                                                },
                                            },
                                        },
                                        {
                                            'instance-type' => 'inner-b',
                                            additionalProperties => 0,
                                            properties => {
                                                'inner-b-elem' => {
                                                    type => 'string',
                                                    enum => ['correct3', 'correct4'],
                                                },
                                            },
                                        },
                                    ],
                                },
                            ],
                        },
                    ],
                },
            ],
        },
        subtests => [
            {
                name => 'instance one',
                in => {
                    first => 'hello',
                    type => 'one',
                    'one-a' => 'hello',
                    'one-b' => 33,
                },
            },
            {
                name => 'instance one bad type check',
                in => {
                    first => 'hello',
                    type => 'one',
                    'one-a' => 'hello',
                    'one-b' => 'hello',
                },
                must_fail => {
                    'oneOf[one].one-b' => qr/^type check \('number'\) failed/,
                },
            },
            {
                name => 'instance two/a, nested optional one-of not set',
                in => {
                    first => 'hello',
                    type => 'two',
                    'two-a' => 33,
                    'two-b' => 'hello',
                },
            },
            {
                name => 'instance two/a/inner-a, inner not filled',
                in => {
                    first => 'hello',
                    type => 'two',
                    'two-a' => 33,
                    'two-b' => 'hello',
                    'inner-type' => 'inner-a',
                },
                must_fail => {
                    'oneOf[two].oneOf[inner-a].inner-a-elem' => qr/^property is missing /,
                },
            },
            {
                name => 'instance two/a/inner-a valid',
                in => {
                    first => 'hello',
                    type => 'two',
                    'two-a' => 33,
                    'two-b' => 'hello',
                    'inner-type' => 'inner-a',
                    'inner-a-elem' => 'correct',
                },
            },
            {
                name => 'instance two/a/inner-b with properties of inner-a',
                in => {
                    first => 'hello',
                    type => 'two',
                    'two-a' => 33,
                    'two-b' => 'hello',
                    'inner-type' => 'inner-b',
                    'inner-a-elem' => 'correct',
                },
                must_fail => {
                    'oneOf[two].oneOf[inner-b].inner-b-elem' => qr/^property is missing /,
                    'inner-a-elem' => qr/^property is not defined /,
                },
            },
            {
                name => 'instance two/a/inner-b valid',
                in => {
                    first => 'hello',
                    type => 'two',
                    'two-a' => 33,
                    'two-b' => 'hello',
                    'inner-type' => 'inner-b',
                    'inner-b-elem' => 'correct3',
                },
            },
        ],
    },
];

for my $test ($check_one_of->@*) {
    subtest $test->{name}, sub {
        for my $subtest ($test->{subtests}->@*) {
            my $name = $subtest->{name} // 'unnamed';
            my $value = { $subtest->{in}->%* }; # shallow clone

            my $errors = {};
            PVE::JSONSchema::check_prop($value, $test->{schema}, undef, $errors);
            my $err_str = join("\n", map { "$_: $errors->{$_}" } sort keys %$errors);

            if (my $expected_errors = $subtest->{must_fail}) {
                for my $key (keys $expected_errors->%*) {
                    my $err = delete($errors->{$key}) // '';
                    like($err, $expected_errors->{$key}, "$name.$key failed as expected");
                }
                my $err_str = join("\n", map { "$_: $errors->{$_}" } sort keys %$errors);
                is($err_str, '', "$name - only expected errors");
            } else {
                is($err_str, '', "$name - no errors");
            }
        }
        done_testing();
    };
}

done_testing();
