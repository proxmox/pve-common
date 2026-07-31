#!/usr/bin/perl
#
use v5.36;

use lib qw(
    ..
    ../../src/
);

use Data::Dumper;

$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Indent = 1;
$Data::Dumper::Terse = 1;

use Test::More;

use PVE::JSONSchema;
use PVE::RESTHandler;

package TestBase {
    use Carp qw(confess);
    use Data::Dumper;
    use Test::More;

    my @all_tests;

    sub register($class, $subclass) {
        push @all_tests, $subclass;
    }

    sub desc($class) {
        confess "implement me";
    }

    sub schema($class) {
        confess "implement me";
    }

    sub invocations($class) {
        confess "implement me";
    }

    sub run_all($class) {
        for my $subclass (@all_tests) {
            subtest $subclass, sub {
                $subclass->run();
                done_testing();
            }
        }
    }

    sub run($class) {
        my $desc = $class->desc();
        my $schema = $class->schema()
            or die "missing schema in test '$desc'";

        # Silence warnings from the Getopt module:
        local $SIG{__WARN__} = sub { };

        my $index = -1;
        for my $invocation ($class->invocations()) {
            ++$index;

            if (my $callback = $invocation->{pre}) {
                $schema = {%$schema};

                $callback->($schema);
            }

            my $opts = eval {
                PVE::JSONSchema::get_options(
                    $schema,
                    $invocation->{args},
                    $invocation->{arg_param},
                    $invocation->{fixed_param},
                    $invocation->{param_mapping_hash},
                );
            };
            my $err = $@;
            my $expected_err = $invocation->{error};

            my $test_desc = $desc;
            if (my $desc = $invocation->{desc}) {
                $test_desc .= " - $desc";
            } else {
                $test_desc .= " - index $index";
            }

            if ($invocation->{error}) {
                is($err, $invocation->{error}, $test_desc);
            } elsif ($err) {
                fail($test_desc);
                note('test produced unexpected error:');
                note($err);
            } else {
                if (!is_deeply($opts, $invocation->{expected}, $test_desc)) {
                    note('Got:');
                    note(Dumper($opts));
                    note('Expected:');
                    note(Dumper($invocation->{expected}));
                    note("=" x 40);
                }
            }
        }
    }
}

my sub usebase(@bases) {
    my $inheritor = caller;
    no strict 'refs';
    @bases = ('main::TestBase') if !@bases;
    push @{"$inheritor\::ISA"}, @bases;
    TestBase->register($inheritor);
}

package SimpleSchema {
    usebase;

    sub desc($class) {
        'simple schemas';
    }

    sub schema($class) {
        {
            additionalProperties => 0,
            properties => {
                str => {
                    type => 'string',
                    description => 'A string.',
                    optional => 1,
                },
                num => {
                    type => 'number',
                    description => 'A number.',
                    optional => 1,
                },
                arr => {
                    type => 'array',
                    description => 'An array of numbers.',
                    optional => 1,
                    items => {
                        type => 'number',
                        description => 'A number.',
                    },
                },
                flag => {
                    type => 'boolean',
                    description => 'An optional boolean flag.',
                    optional => 1,
                },
                str2 => {
                    type => 'string',
                    description => 'Another string.',
                    optional => 1,
                },
            },
        };
    }

    # Derived tests use this, so we let this walk the tree:
    sub make_param_mandatory($class, $schema, $param) {
        if (my $props = $schema->{properties}) {
            if (my $p = $props->{$param}) {
                delete $p->{optional};
                return 1;
            }
        }

        if (my $all_of = $schema->{allOf}) {
            for my $subschema ($all_of->@*) {
                return 1 if __SUB__->($class, $subschema, $param);
            }
        }

        if (my $one_of = $schema->{oneOf}) {
            for my $subschema ($one_of->@*) {
                return 1 if __SUB__->($class, $subschema, $param);
            }
        }

        return;
    }

    sub invocations($class) {
        return (
            {
                args => [qw(--flag)],
                expected => { 'flag' => 1 },
            },
            {
                args => [qw(--typoed-flags)],
                error => "400 unable to parse option\n",
            },
            {
                desc => 'boolean flag followed by an option should work',
                args => [qw(--flag --str hello)],
                expected => {
                    'flag' => 1,
                    str => 'hello',
                },
            },
            {
                desc => "arg_param",
                arg_param => ['num'],
                args => [qw(33 --flag --str hello)],
                expected => {
                    num => 33,
                    'flag' => 1,
                    str => 'hello',
                },
            },
            {
                desc => "optional arg_param is optional",
                arg_param => ['num'],
                args => [qw(--flag)],
                expected => { 'flag' => 1 },
            },
            {
                desc => "mandatory arg_param is checked at parse time",
                pre => sub($schema) {
                    $class->make_param_mandatory($schema, 'num');
                },
                arg_param => ['num'],
                args => [qw(--flag)],
                error => "400 not enough arguments\n",
            },
            {
                desc => "arg_param does not affect what '--options' do",
                arg_param => ['str'],
                args => [qw(--33 --flag --num 44)],
                error => "400 unable to parse option\n",
            },
            {
                desc => "arg_param at the front",
                arg_param => ['str'],
                args => [qw(foo --flag --num 44)],
                expected => {
                    num => 44,
                    'flag' => 1,
                    str => 'foo',
                },
            },
            {
                desc => "arg_param at the end",
                arg_param => ['str'],
                args => [qw(--flag --num 44 foo)],
                expected => {
                    num => 44,
                    'flag' => 1,
                    str => 'foo',
                },
            },
            {
                desc => "arg_param with explicit '--' separator",
                arg_param => ['str'],
                args => [qw(--flag --num 44 -- foo)],
                expected => {
                    num => 44,
                    'flag' => 1,
                    str => 'foo',
                },
            },
            {
                desc => "arg_param with explicit '--' separator with '--option' lookalike",
                arg_param => ['str'],
                args => [qw(--flag --num 44 -- --foo)],
                expected => {
                    num => 44,
                    'flag' => 1,
                    str => '--foo',
                },
            },
            {
                desc => "array parameters used once are perl arrays",
                args => [qw(--arr 3)],
                expected => {
                    arr => [3],
                },
            },
            {
                desc => "array parameters used multiple times",
                args => [qw(--arr 3 --arr 4)],
                expected => {
                    arr => [3, 4],
                },
            },
            {
                desc => "mandatory flags don't affect the get_options parser",
                pre => sub($schema) {
                    $class->make_param_mandatory($schema, 'num');
                },
                args => [qw(--flag --str hello)],
                expected => {
                    'flag' => 1,
                    str => 'hello',
                },
            },
            {
                desc => 'fixed options work',
                fixed_param => { str2 => 'hello' },
                args => [qw(--str something)],
                expected => {
                    str => 'something',
                    str2 => 'hello',
                },
            },
            {
                desc => 'extra args work',
                arg_param => ['extra-args'],
                args => [qw(--str foo --flag -- more args)],
                expected => {
                    str => 'foo',
                    flag => 1,
                    'extra-args' => [qw(more args)],
                },
            },
            {
                desc => "extra args work without 'extra-args' fail",
                args => [qw(--str foo --flag -- more args)],
                error => "400 too many arguments\n",
            },
        );
    }
}

package SingleAllOf {
    usebase 'SimpleSchema';

    sub desc($class) {
        'simple all-of';
    }

    sub schema($class) {
        { allOf => [SimpleSchema->schema()] };
    }
}

package ManyAllOf {
    usebase 'SingleAllOf';

    sub desc($class) {
        'many allOf entries';
    }

    sub schema($class) {
        my $properties = SimpleSchema->schema()->{properties};
        my $all_of = [];
        for my $key (keys $properties->%*) {
            push $all_of->@*,
                {
                    additionalProperties => 0,
                    properties => { $key => $properties->{$key} },
                };
        }
        return { allOf => $all_of };
    }
}

package NestedAllOf {
    usebase 'SingleAllOf';

    sub desc($class) {
        'nested allOf entries';
    }

    sub schema($class) {
        my $properties = SimpleSchema->schema()->{properties};
        my $schema;
        for my $key (keys $properties->%*) {
            my $object = {
                additionalProperties => 0,
                properties => { $key => $properties->{$key} },
            };

            if ($schema) {
                $schema = { allOf => [$object, $schema] };
            } else {
                $schema = $object;
            }
        }
        return $schema;
    }
}

package DirectOneOf {
    usebase;

    sub desc($class) {
        'oneOf as top-level';
    }

    sub schema($class) {
        {
            'type-property' => 'type',
            'type-property-schema' => {
                type => 'string',
                description => 'The type.',
                enum => ['one', 'two'],
            },
            oneOf => [
                {
                    'instance-type' => 'one',
                    additionalProperties => 0,
                    properties => {
                        'prop-one' => {
                            optional => 1,
                            type => 'string',
                            description => 'a or b',
                            enum => ['a', 'b'],
                        },
                    },
                },
                {
                    'instance-type' => 'two',
                    additionalProperties => 0,
                    properties => {
                        'prop-two' => {
                            type => 'number',
                            description => 'number',
                            minimum => 3,
                            maximum => 100,
                        },
                    },
                },
            ],
        };
    }

    sub invocations($class) {
        return (
            {
                desc => "type parameter works",
                args => [qw(--type one)],
                expected => {
                    type => 'one',
                },
            },
            {
                desc => "valid options parse",
                args => [qw(--type one --prop-one a)],
                expected => {
                    type => 'one',
                    'prop-one' => 'a',
                },
            },
            {
                desc => "type is not checked at getopt time",
                args => [qw(--type two --prop-one a)],
                expected => {
                    type => 'two',
                    'prop-one' => 'a',
                },
            },
            {
                desc => "invalid options are rejected",
                args => [qw(--type two --prop-invalid a)],
                error => "400 unable to parse option\n",
            },
            {
                desc => "optional arg_param is optional",
                args => [qw(--type one)],
                arg_param => [qw(prop-one)],
                expected => {
                    type => 'one',
                },
            },
            {
                desc => "optional arg_param is functional",
                args => [qw(--type one b)],
                arg_param => [qw(prop-one)],
                expected => {
                    type => 'one',
                    'prop-one' => 'b',
                },
            },
            {
                desc => "mandatory arg_param is mandatory",
                args => [qw(--type two)],
                arg_param => [qw(prop-two)],
                error => "400 not enough arguments\n",
            },
            {
                desc => "mandatory arg_param is is functional",
                args => [qw(--type two 33)],
                arg_param => [qw(prop-two)],
                expected => {
                    type => 'two',
                    'prop-two' => 33,
                },
            },
        );
    }
}

package OneOfArrayVsScalar {
    usebase;

    sub desc($class) {
        'oneOf with clashing parameter array vs scalar';
    }

    sub schema($class) {
        {
            'type-property' => 'type',
            'type-property-schema' => {
                type => 'string',
                description => 'The type.',
                enum => ['one', 'two'],
            },
            oneOf => [
                {
                    'instance-type' => 'one',
                    additionalProperties => 0,
                    properties => {
                        'values' => {
                            optional => 1,
                            type => 'array',
                            description => 'An array.',
                            items => {
                                type => 'string',
                                description => 'An item in the array.',
                            },
                        },
                    },
                },
                {
                    'instance-type' => 'two',
                    additionalProperties => 0,
                    properties => {
                        'values' => {
                            type => 'string',
                            # a non-list format must not skip the un-array-ification
                            format => 'pve-configid',
                            description => 'A single string.',
                        },
                    },
                },
            ],
        };
    }

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix --type <string> [OPTIONS]\n"
            . "  --type     <one | two>\n"
            . "\t     The type.\n" . "\n"
            . " Conditional options:\n" . "\n"
            . " [type=one]\n" . "\n"
            . "  --values   <array>\n"
            . "\t     An array.\n" . "\n"
            . " [type=two]\n" . "\n"
            . "  --values   <string>\n"
            . "\t     A single string.\n" . "\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "array variant",
                args => [qw(--type one --values foo --values bar)],
                expected => {
                    type => 'one',
                    values => [qw(foo bar)],
                },
            },
            {
                desc => "scalar variant",
                args => [qw(--type two --values foo)],
                expected => {
                    type => 'two',
                    values => 'foo',
                },
            },
        );
    }
}

package OneOfInAllOf {
    usebase;

    sub desc($class) {
        'oneOf in an allOf';
    }

    sub schema($class) {
        {
            allOf => [
                {
                    additionalProperties => 0,
                    properties => {
                        mandatory => {
                            type => 'string',
                            description => 'mandatory string',
                        },
                        flag => {
                            type => 'boolean',
                            description => 'optional flag',
                            optional => 1,
                        },
                    },
                },
                {
                    'type-property' => 'type',
                    'type-property-schema' => {
                        type => 'string',
                        description => 'The type.',
                        enum => ['one', 'two'],
                    },
                    oneOf => [
                        {
                            'instance-type' => 'one',
                            additionalProperties => 0,
                            properties => {
                                'prop-one' => {
                                    optional => 1,
                                    type => 'string',
                                    description => 'a or b',
                                    enum => ['a', 'b'],
                                },
                                flag1 => {
                                    type => 'boolean',
                                    description => 'required flag',
                                },
                            },
                        },
                        {
                            'instance-type' => 'two',
                            additionalProperties => 0,
                            properties => {
                                'prop-two' => {
                                    type => 'number',
                                    description => 'number',
                                    minimum => 3,
                                    maximum => 100,
                                },
                                flag2 => {
                                    type => 'boolean',
                                    description => 'optional flag',
                                    optional => 1,
                                },
                            },
                        },
                    ],
                },
            ],
        };
    }

    sub invocations($class) {
        return (
            {
                desc => "basics work",
                args => [qw(--type one --mandatory foo --flag)],
                expected => {
                    type => 'one',
                    mandatory => 'foo',
                    flag => 1,
                },
            },
            {
                desc => "basic oneOf properties work",
                args => [qw(--type one --mandatory foo --flag1 --flag)],
                expected => {
                    type => 'one',
                    mandatory => 'foo',
                    flag => 1,
                    flag1 => 1,
                },
            },
            {
                desc => "other type works",
                args => [qw(--type two --mandatory foo --flag2)],
                expected => {
                    type => 'two',
                    mandatory => 'foo',
                    flag2 => 1,
                },
            },
        );
    }
}

TestBase->run_all();
done_testing();
