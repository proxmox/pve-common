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

package TestBase {
    use Carp qw(confess);
    use Clone qw(clone);
    use Data::Dumper;
    use Test::More;

    use PVE::RESTHandler;
    use base 'PVE::RESTHandler';

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

    sub long_usage_str($class, $prefix) {
        confess "implement me";
    }

    # The remaining `usage_str` inputs, overridden by tests which want to cover them.

    sub usage_arg_param($class) {
        return [];
    }

    sub usage_param_cb($class) {
        return undef;
    }

    sub usage_formatter_properties($class) {
        return undef;
    }

    sub additional_method_info($class) {
        return;
    }

    my sub build_rest_handler($class) {
        for my $subclass (@all_tests) {
            my %additional_method_info = $subclass->additional_method_info();

            $class->register_method({
                name => $subclass,
                path => $subclass,
                method => 'POST',
                parameters => $subclass->schema(),
                returns => { type => 'object' },
                code => sub {
                    my ($param) = @_;
                    return $param;
                },
                %additional_method_info,
            });
        }
    }

    sub run_all($class) {
        build_rest_handler($class);

        for my $subclass (@all_tests) {
            subtest $subclass, sub {
                $class->run($subclass);
                done_testing();
            }
        }

        subtest 'usage strings', sub {
            $class->test_usage_strings();
            done_testing();
        };

        done_testing();
    }

    sub run($class, $subclass) {
        my $desc = $subclass->desc();

        # Silence warnings from the Getopt module:
        local $SIG{__WARN__} = sub { };

        my $index = -1;
        for my $invocation ($subclass->invocations()) {
            ++$index;

            my $original_parameters;
            my $info = $class->map_method_by_name($subclass);
            if (my $callback = $invocation->{pre}) {
                $original_parameters = clone($info->{parameters});
                $callback->($info->{parameters});
            }

            my $prefix = "cli $subclass";
            my ($opts, $fmt_param) = eval {
                $class->cli_handler(
                    $prefix, # prefix
                    $subclass, # name
                    $invocation->{args},
                    $invocation->{arg_param},
                    $invocation->{fixed_param},
                    $subclass->usage_param_cb(),
                    $subclass->usage_formatter_properties(),
                );
            };
            my $err = $@;
            my $expected_err = $invocation->{error};

            if ($original_parameters) {
                $info->{parameters} = $original_parameters;
            }

            my $test_desc = $desc;
            if (my $desc = $invocation->{desc}) {
                $test_desc .= " - $desc";
            } else {
                $test_desc .= " - index $index";
            }

            if ($err) {
                if (!$expected_err) {
                    fail($test_desc);
                    note('Test produced unexpected error:');
                    note($err);
                    note(Dumper($err));
                    note("=" x 40);
                } elsif (ref($expected_err)) {
                    if (!ref($err)) {
                        fail("$test_desc - should have produced a PVE::Exception");
                    } else {
                        my $errors = $err->{errors};
                        subtest "$test_desc - multiple errors", sub {
                            for my $key ($expected_err->%*) {
                                is(
                                    delete($errors->{$key}),
                                    $expected_err->{$key},
                                    "$test_desc - $key",
                                );
                            }
                            is_deeply($errors, {}, "$test_desc - no unexpected errors");
                            done_testing();
                        };
                    }
                } else {
                    if (ref($err) && ref($err) eq 'PVE::Exception') {
                        # Makes comparison annoying.
                        # Only testing $err->{msg} would not test the HTTP status code.
                        delete $err->{usage};
                    }
                    is("$err", $expected_err, $test_desc);
                }
            } elsif ($expected_err) {
                fail($test_desc);
                note('Test returned unexpected success');
                note('Got:');
                note(Dumper($opts));
                note('Expected:');
                chomp($expected_err);
                note($expected_err);
                note("=" x 40);
            } else {
                if (!is_deeply($opts, $invocation->{expected}, $test_desc)) {
                    note('Got:');
                    note(Dumper($opts));
                    note('Expected:');
                    note(Dumper($invocation->{expected}));
                    note("=" x 40);
                }
                is_deeply(
                    $fmt_param,
                    $invocation->{expected_format_options} // {},
                    "$test_desc - format options",
                ) if $subclass->usage_formatter_properties();
            }
        }
    }

    sub test_usage_strings($class) {
        for my $subclass (@all_tests) {
            my $prefix = "test $subclass";
            my $expected = $subclass->long_usage_str($prefix);
            next if !defined($expected);

            my $got = $class->usage_str(
                $subclass, # name
                $prefix, # prefix
                $subclass->usage_arg_param(),
                {}, # fixed_param
                'long', # format
                $subclass->usage_param_cb(),
                $subclass->usage_formatter_properties(),
            );

            my $desc = $subclass->desc();

            is($got, $expected, "$desc - long usage description matches");
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

    use PVE::JSONSchema;

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

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix  [OPTIONS]\n"
            . "  --arr      <array>\n"
            . "\t     An array of numbers.\n" . "\n"
            . "  --flag     <boolean>\n"
            . "\t     An optional boolean flag.\n" . "\n"
            . "  --num      <number>\n"
            . "\t     A number.\n" . "\n"
            . "  --str      <string>\n"
            . "\t     A string.\n" . "\n"
            . "  --str2     <string>\n"
            . "\t     Another string.\n" . "\n";
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

    my sub add_extra_args($schema) {
        my $orig = {%$schema};
        $schema->%* = (
            allOf => [
                $orig,
                {
                    additionalProperties => 0,
                    properties => {
                        'extra-args' => PVE::JSONSchema::get_standard_option('extra-args'),
                    },
                },
            ],
        );
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
                pre => sub($schema) {
                    add_extra_args($schema);
                },
                arg_param => ['extra-args'],
                args => [qw(--str foo --flag -- more args)],
                expected => {
                    str => 'foo',
                    flag => 1,
                    'extra-args' => [qw(more args)],
                },
            },
            {
                desc => "extra args work without 'extra-args' arg_param fail",
                pre => sub($schema) {
                    add_extra_args($schema);
                },
                args => [qw(--str foo --flag -- more args)],
                error => "400 too many arguments\n",
            },
        );
    }
}

# Covers the parts of the usage string which do not come from the properties themselves:
# positional 'arg_param's, the collapsing of indexed options, aliases, parameter mappings and
# the formatter properties.
package UsageStringDetails {
    usebase;

    sub desc($class) {
        'usage string details';
    }

    sub schema($class) {
        {
            additionalProperties => 0,
            properties => {
                vmid => {
                    type => 'integer',
                    description => 'The ID.',
                },
                net0 => {
                    type => 'string',
                    description => 'Network device 0.',
                    optional => 1,
                },
                net1 => {
                    type => 'string',
                    description => 'Network device 1.',
                    optional => 1,
                },
                ide => {
                    type => 'string',
                    description => 'An IDE device.',
                    optional => 1,
                },
                disk => {
                    alias => 'ide',
                },
                password => {
                    type => 'string',
                    description => 'The password.',
                    optional => 1,
                },
            },
        };
    }

    sub usage_arg_param($class) {
        return ['vmid'];
    }

    sub usage_param_cb($class) {
        return sub {
            return [{ name => 'password', desc => '<filepath>', func => sub { return $_[0] } }];
        };
    }

    sub usage_formatter_properties($class) {
        return $PVE::RESTHandler::standard_output_options;
    }

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix <vmid> [OPTIONS] [FORMAT_OPTIONS]\n"
            . "  <vmid>     <integer>\n"
            . "\t     The ID.\n" . "\n"
            . "  --disk     <alias to 'ide'>\n" . "\n"
            . "  --ide      <string>\n"
            . "\t     An IDE device.\n" . "\n"
            . "  --net[n]   <string>\n"
            . "\t     Network device 0.\n" . "\n"
            . "  --password <filepath>\n"
            . "\t     The password.\n" . "\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "positional argument and an indexed option",
                args => [qw(--net1 model=e1000 100)],
                arg_param => ['vmid'],
                expected => {
                    vmid => '100',
                    net1 => 'model=e1000',
                },
            },
            {
                desc => "alias is remapped to its target",
                args => [qw(--disk local:1 100)],
                arg_param => ['vmid'],
                expected => {
                    vmid => '100',
                    ide => 'local:1',
                },
            },
            {
                desc => "formatter properties are parsed and split off",
                args => [qw(--output-format json --noborder 1 100)],
                arg_param => ['vmid'],
                expected => {
                    vmid => '100',
                },
                expected_format_options => {
                    'output-format' => 'json',
                    noborder => 1,
                },
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

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix --type <string> [OPTIONS]\n"
            . "  --type     <one | two>\n"
            . "\t     The type.\n" . "\n"
            . " Conditional options:\n" . "\n"
            . " [type=one]\n" . "\n"
            . "  --prop-one <a | b>\n"
            . "\t     a or b\n" . "\n"
            . " [type=two]\n" . "\n"
            . "  --prop-two <number> (3 - 100)\n"
            . "\t     number\n" . "\n";
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

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix"
            . " --mandatory <string>"
            . " --type <string> [OPTIONS]\n"
            . "  --flag     <boolean>\n"
            . "\t     optional flag\n" . "\n"
            . "  --mandatory <string>\n"
            . "\t     mandatory string\n" . "\n"
            . "  --type     <one | two>\n"
            . "\t     The type.\n" . "\n"
            . " Conditional options:\n" . "\n"
            . " [type=one]\n" . "\n"
            . "  --flag1    <boolean>\n"
            . "\t     required flag\n" . "\n"
            . "  --prop-one <a | b>\n"
            . "\t     a or b\n" . "\n"
            . " [type=two]\n" . "\n"
            . "  --flag2    <boolean>\n"
            . "\t     optional flag\n" . "\n"
            . "  --prop-two <number> (3 - 100)\n"
            . "\t     number\n" . "\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "basics work",
                args => [qw(--type one --mandatory foo --flag --flag1)],
                expected => {
                    type => 'one',
                    mandatory => 'foo',
                    flag => 1,
                    flag1 => 1,
                },
            },
            {
                desc => "type specific mandator parameter is checked",
                args => [qw(--type one --mandatory foo --flag)],
                error => {
                    'oneOf[one].flag1' => 'property is missing and it is not optional',
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
                args => [qw(--type two --mandatory foo --flag2 --prop-two 44)],
                expected => {
                    type => 'two',
                    mandatory => 'foo',
                    flag2 => 1,
                    'prop-two' => 44,
                },
            },
            {
                desc => "other type mandatory parameter is checked",
                args => [qw(--type two --mandatory foo --flag2)],
                error => {
                    'oneOf[two].prop-two' => 'property is missing and it is not optional',
                },
            },
        );
    }
}

package AllOfInOneOf {
    usebase;

    sub desc($class) {
        'allOf in oneOf';
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
                            description => 'a string',
                        },
                    },
                },
                {
                    'instance-type' => 'two',
                    allOf => [
                        {
                            additionalProperties => 0,
                            properties => {
                                'prop-two' => {
                                    type => 'number',
                                    description => 'number',
                                },
                            },
                        },
                    ],
                },
            ],
        };
    }

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix"
            . " --type <string> [OPTIONS]\n"
            . "  --type     <one | two>\n"
            . "\t     The type.\n" . "\n"
            . " Conditional options:\n" . "\n"
            . " [type=one]\n" . "\n"
            . "  --prop-one <string>\n"
            . "\t     a string\n" . "\n"
            . " [type=two]\n" . "\n"
            . "  --prop-two <number>\n"
            . "\t     number\n" . "\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "first type",
                args => [qw(--type one --prop-one foo)],
                expected => {
                    type => 'one',
                    'prop-one' => 'foo',
                },
            },
            {
                desc => "second type",
                args => [qw(--type two --prop-two 123)],
                expected => {
                    type => 'two',
                    'prop-two' => 123,
                },
            },
        );
    }
}

package NestedOneOf {
    usebase;

    sub desc($class) {
        'nested oneOf';
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
                            description => 'a string',
                        },
                    },
                },
                {
                    'instance-type' => 'two',
                    allOf => [
                        {
                            additionalProperties => 0,
                            properties => {
                                'prop-two' => {
                                    type => 'number',
                                    description => 'number',
                                },
                            },
                        },
                        {
                            optional => 1,
                            'type-property' => 'inner-type',
                            'type-property-schema' => {
                                type => 'string',
                                description => 'Inner type.',
                                enum => [qw(inner1 inner2)],
                            },
                            oneOf => [
                                {
                                    'instance-type' => 'inner1',
                                    additionalProperties => 0,
                                    properties => {
                                        'prop-inner' => {
                                            type => 'string',
                                            description => 'an inner string',
                                        },
                                    },
                                },
                                {
                                    'instance-type' => 'inner2',
                                    additionalProperties => 0,
                                    properties => {
                                        'prop-inner' => {
                                            type => 'number',
                                            description => 'an inner number',
                                        },
                                    },
                                },
                            ],
                        },
                    ],
                },
            ],
        };
    }

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix"
            . " --type <string> [OPTIONS]\n"
            . "  --type     <one | two>\n"
            . "\t     The type.\n" . "\n"
            . " Conditional options:\n" . "\n"
            . " [type=one]\n" . "\n"
            . "  --prop-one <string>\n"
            . "\t     a string\n" . "\n"
            . " [type=two]\n" . "\n"
            . "  --inner-type <inner1 | inner2>\n"
            . "\t     Inner type.\n" . "\n"
            . "  --prop-two <number>\n"
            . "\t     number\n" . "\n"
            . " [type=two and inner-type=inner1]\n" . "\n"
            . "  --prop-inner <string>\n"
            . "\t     an inner string\n" . "\n"
            . " [type=two and inner-type=inner2]\n" . "\n"
            . "  --prop-inner <number>\n"
            . "\t     an inner number\n" . "\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "first type",
                args => [qw(--type one --prop-one foo)],
                expected => {
                    type => 'one',
                    'prop-one' => 'foo',
                },
            },
            {
                desc => "second type",
                args => [qw(--type two --prop-two 99)],
                expected => {
                    type => 'two',
                    'prop-two' => 99,
                },
            },
            {
                desc => "second type with inner oneOf",
                args => [qw(--type two --prop-two 7 --inner-type inner1 --prop-inner works)],
                expected => {
                    type => 'two',
                    'prop-two' => 7,
                    'inner-type' => 'inner1',
                    'prop-inner' => 'works',
                },
            },
        );
    }
}

package SectionConfigTest {

    package SectionConfigTest::PluginBase {
        use base 'PVE::SectionConfig';

        my $DEFAULT_DATA = {
            propertyIsolation => 1,
            propertyList => {
                common => {
                    type => 'string',
                    description => 'A common string.',
                    optional => 1,
                },
            },
        };

        sub private($class) {
            return $DEFAULT_DATA;
        }
    }

    package SectionConfigTest::PluginOne {
        use base 'SectionConfigTest::PluginBase';

        sub type($class) {
            return 'one';
        }

        sub properties($class) {
            return {
                'prop-one' => {
                    type => 'string',
                    description => "A string for type one.",
                    optional => 1,
                },
            };
        }

        sub options($class) {
            return { common => { optional => 0 } };
        }
    }

    package SectionConfigTest::PluginTwo {
        use base 'SectionConfigTest::PluginBase';

        sub type($class) {
            return 'two';
        }

        sub properties($class) {
            return {
                'prop-two' => {
                    type => 'string',
                    description => "A string for type two.",
                    optional => 1,
                },
            };
        }

        sub options($class) {
            return { common => { optional => 0 } };
        }
    }

    SectionConfigTest::PluginOne->register();
    SectionConfigTest::PluginTwo->register();
    SectionConfigTest::PluginBase->init();
}

package SectionConfigTestCreate {
    usebase;

    sub desc($class) {
        'section config createSchema';
    }

    sub schema($class) {
        return SectionConfigTest::PluginBase->createSchema();
    }

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix"
            . " --type <string> [OPTIONS]\n"
            . "  --type     <one | two>\n"
            . "\t     Section Type\n" . "\n"
            . " Conditional options:\n" . "\n"
            . " [type=one]\n" . "\n"
            . "  --common   <string>\n"
            . "\t     A common string.\n" . "\n"
            . "  --prop-one <string>\n"
            . "\t     A string for type one.\n" . "\n"
            . " [type=two]\n" . "\n"
            . "  --common   <string>\n"
            . "\t     A common string.\n" . "\n"
            . "  --prop-two <string>\n"
            . "\t     A string for type two.\n" . "\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "first type",
                args => [qw(--common okay --type one --prop-one foo)],
                expected => {
                    common => 'okay',
                    type => 'one',
                    'prop-one' => 'foo',
                },
            },
            {
                desc => "second type",
                args => [qw(--type two --prop-two bar --common omg)],
                expected => {
                    common => 'omg',
                    type => 'two',
                    'prop-two' => 'bar',
                },
            },
        );
    }
};

my $UPDATE_SCHEMA_DEFAULT_PROPERTIES = {
    digest => {
        optional => 1,
        type => 'string',
        description => 'Prevent changes if current configuration file has a'
            . ' different digest. This can be used to prevent concurrent'
            . ' modifications.',
        maxLength => 64,
    },
    delete => {
        description => 'A list of settings you want to delete.',
        maxLength => 4096,
        format => 'pve-configid-list',
        optional => 1,
        type => 'string',
    },
};

package SectionConfigTestUpdate {
    usebase;

    sub desc($class) {
        'section config updateSchema';
    }

    sub schema($class) {
        return SectionConfigTest::PluginBase->updateSchema();
    }

    sub additional_method_info($class) {
        return (
            resolve_type => sub {
                my ($param) = @_;
                return 'one' if $param->{common} eq 'use-type-one';
                return 'two' if $param->{common} eq 'use-type-two';
                die "no such type\n" if $param->{common} eq 'resolve-error';
                return;
            },
        );
    }

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix"
            . "  [OPTIONS]\n"
            . "  --delete   <string>\n"
            . "\t     A list of settings you want to delete.\n" . "\n"
            . "  --digest   <string>\n"
            . "\t     Prevent changes if current configuration file has a different\n"
            . "\t     digest. This can be used to prevent concurrent modifications.\n" . "\n"
            . "  --type     <one | two>\n"
            . "\t     Section Type\n" . "\n"
            . " Conditional options:\n" . "\n"
            . " [type=one]\n" . "\n"
            . "  --common   <string>\n"
            . "\t     A common string.\n" . "\n"
            . "  --prop-one <string>\n"
            . "\t     A string for type one.\n" . "\n"
            . " [type=two]\n" . "\n"
            . "  --common   <string>\n"
            . "\t     A common string.\n" . "\n"
            . "  --prop-two <string>\n"
            . "\t     A string for type two.\n" . "\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "first type",
                args => [qw(--common okay --type one --prop-one foo)],
                expected => {
                    common => 'okay',
                    type => 'one',
                    'prop-one' => 'foo',
                },
            },
            {
                desc => "second type",
                args => [qw(--type two --prop-two bar --common omg)],
                expected => {
                    common => 'omg',
                    type => 'two',
                    'prop-two' => 'bar',
                },
            },
            {
                desc => "resolve to first type",
                args => [qw(--common use-type-one --prop-one foo)],
                expected => {
                    common => 'use-type-one',
                    type => 'one',
                    'prop-one' => 'foo',
                },
            },
            {
                desc => "resolve to second type",
                args => [qw(--common use-type-two --prop-two bar)],
                expected => {
                    common => 'use-type-two',
                    type => 'two',
                    'prop-two' => 'bar',
                },
            },
            {
                desc => "type resolution failure",
                args => [qw(--common resolve-error)],
                error => "no such type\n",
            },
        );
    }
};

TestBase->run_all();
