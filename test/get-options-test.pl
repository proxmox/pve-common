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

    sub asciidoc_usage_str($class, $prefix) {
        return undef;
    }

    # Usage for given parameters, as hashes with 'desc', 'given', 'expected' and 'arg_param'.
    sub given_usage_strs($class, $prefix) {
        return ();
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
            my $desc = $subclass->desc();

            for my $given ($subclass->given_usage_strs($prefix)) {
                my $got = $class->usage_str(
                    $subclass,
                    $prefix,
                    $given->{arg_param} // $subclass->usage_arg_param(),
                    {},
                    'long',
                    $subclass->usage_param_cb(),
                    $subclass->usage_formatter_properties(),
                    $given->{given},
                );
                is($got, $given->{expected}, "$desc - usage with $given->{desc}");
            }

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

            is($got, $expected, "$desc - long usage description matches");

            $expected = $subclass->asciidoc_usage_str($prefix) // next;
            $got = $class->usage_str(
                $subclass,
                $prefix,
                $subclass->usage_arg_param(),
                {},
                'asciidoc',
                $subclass->usage_param_cb(),
                $subclass->usage_formatter_properties(),
            );
            is($got, $expected, "$desc - asciidoc usage description matches");
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
            . "  --prop-one <a | b>\n"
            . "\t     a or b\n"
            . "\t     [type=one]\n" . "\n"
            . "  --prop-two <number> (3 - 100)\n"
            . "\t     number\n"
            . "\t     [type=two]\n" . "\n";
    }

    sub given_usage_strs($class, $prefix) {
        return (
            {
                desc => 'the type given as option',
                given => { type => 'two' },
                expected => "USAGE: $prefix --prop-two <number> --type two [OPTIONS]\n"
                    . "  --prop-two <number> (3 - 100)\n"
                    . "\t     number\n" . "\n",
            },
            {
                desc => 'the type given as argument',
                arg_param => ['type'],
                given => { type => 'one' },
                expected => "USAGE: $prefix one [OPTIONS]\n"
                    . "  --prop-one <a | b>\n"
                    . "\t     a or b\n" . "\n",
            },
            {
                desc => 'an unknown type given',
                given => { type => 'three' },
                expected => $class->long_usage_str($prefix),
            },
        );
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
                desc => "mandatory arg_param is functional",
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

package OneOfWithCustomResolvedTypeProperty {
    usebase;

    sub desc($class) {
        "oneOf as top-level with a custom 'type-property' that is resolved via 'resolve_type'";
    }

    sub schema($class) {
        my $implicit_type_discriminator = {
            type => 'string',
            description => 'A property from which the type can be deduced.',
            enum => ['deduce-type-one', 'deduce-type-two'],
        };
        return {
            'type-property' => 'custom-type',
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
                        'implicit-type-discriminator' => $implicit_type_discriminator,
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
                        'implicit-type-discriminator' => $implicit_type_discriminator,
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

    sub additional_method_info($class) {
        return (
            resolve_type => sub {
                my ($param) = @_;
                return 'one' if $param->{'implicit-type-discriminator'} eq 'deduce-type-one';
                return 'two' if $param->{'implicit-type-discriminator'} eq 'deduce-type-two';
                die "unable to resolve type\n";
            },
        );
    }

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix --implicit-type-discriminator <string> [OPTIONS]\n"
            . "  --custom-type <one | two>\n"
            . "\t     The type.\n" . "\n"
            . "  --implicit-type-discriminator <deduce-type-one | deduce-type-two>\n"
            . "\t     A property from which the type can be deduced.\n" . "\n"
            . " Conditional options:\n" . "\n"
            . "  --prop-one <a | b>\n"
            . "\t     a or b\n"
            . "\t     [custom-type=one]\n" . "\n"
            . "  --prop-two <number> (3 - 100)\n"
            . "\t     number\n"
            . "\t     [custom-type=two]\n" . "\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "implicit-type-discriminator parameter works",
                args => [qw(--implicit-type-discriminator deduce-type-one)],
                expected => {
                    'custom-type' => 'one',
                    'implicit-type-discriminator' => 'deduce-type-one',
                },
            },
            {
                desc => "valid options parse",
                args => [qw(--implicit-type-discriminator deduce-type-one --prop-one a)],
                expected => {
                    'custom-type' => 'one',
                    'implicit-type-discriminator' => 'deduce-type-one',
                    'prop-one' => 'a',
                },
            },
            {
                desc => "invalid options are rejected",
                args => [qw(--implicit-type-discriminator deduce-type-one --prop-invalid a)],
                error => "400 unable to parse option\n",
            },
            {
                desc => "optional arg_param is optional",
                args => [qw(--implicit-type-discriminator deduce-type-one)],
                arg_param => [qw(prop-one)],
                expected => {
                    'custom-type' => 'one',
                    'implicit-type-discriminator' => 'deduce-type-one',
                },
            },
            {
                desc => "optional arg_param is functional",
                args => [qw(--implicit-type-discriminator deduce-type-one b)],
                arg_param => [qw(prop-one)],
                expected => {
                    'custom-type' => 'one',
                    'implicit-type-discriminator' => 'deduce-type-one',
                    'prop-one' => 'b',
                },
            },
            {
                desc => "mandatory arg_param is mandatory",
                args => [qw(--implicit-type-discriminator deduce-type-two)],
                arg_param => [qw(prop-two)],
                error => "400 not enough arguments\n",
            },
            {
                desc => "mandatory arg_param is is functional",
                args => [qw(--implicit-type-discriminator deduce-type-two 33)],
                arg_param => [qw(prop-two)],
                expected => {
                    'custom-type' => 'two',
                    'implicit-type-discriminator' => 'deduce-type-two',
                    'prop-two' => 33,
                },
            },
            {
                desc => "explicit type takes precedence",
                args => [qw(--implicit-type-discriminator deduce-type-two --custom-type one)],
                expected => {
                    'custom-type' => 'one',
                    'implicit-type-discriminator' => 'deduce-type-two',
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
            . "  --values   <array>\n"
            . "\t     An array.\n"
            . "\t     [type=one]\n" . "\n"
            . "  --values   <string>\n"
            . "\t     A single string.\n"
            . "\t     [type=two]\n" . "\n";
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

package OneOfFlagVsString {
    usebase;

    sub desc($class) {
        'oneOf with clashing parameter flag vs string and a resolved type';
    }

    sub schema($class) {
        {
            allOf => [
                {
                    additionalProperties => 0,
                    properties => {
                        id => {
                            type => 'string',
                            description => 'The ID, which determines the type.',
                            enum => ['flagged', 'worded'],
                        },
                    },
                },
                {
                    'type-property' => 'type',
                    'type-property-schema' => {
                        type => 'string',
                        description => 'The type.',
                        enum => ['flag', 'word'],
                    },
                    oneOf => [
                        {
                            'instance-type' => 'flag',
                            additionalProperties => 0,
                            properties => {
                                'mode' => {
                                    optional => 1,
                                    type => 'boolean',
                                    description => 'A flag.',
                                },
                            },
                        },
                        {
                            'instance-type' => 'word',
                            additionalProperties => 0,
                            properties => {
                                'mode' => {
                                    optional => 1,
                                    type => 'string',
                                    description => 'A word.',
                                    enum => ['on', 'off', 'auto'],
                                },
                            },
                        },
                    ],
                },
            ],
        };
    }

    sub additional_method_info($class) {
        return (
            resolve_type => sub {
                my ($param) = @_;
                return 'flag' if $param->{id} eq 'flagged';
                return 'word' if $param->{id} eq 'worded';
                die "unable to resolve type\n";
            },
        );
    }

    # wraps the schema in a further allOf
    sub usage_formatter_properties($class) {
        return {
            quiet => {
                type => 'boolean',
                description => 'Be quiet.',
                optional => 1,
            },
        };
    }

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix --id <string> [OPTIONS]\n"
            . "  --id\t     <flagged | worded>\n"
            . "\t     The ID, which determines the type.\n" . "\n"
            . "  --type     <flag | word>\n"
            . "\t     The type.\n" . "\n"
            . " Conditional options:\n" . "\n"
            . "  --mode     <boolean>\n"
            . "\t     A flag.\n"
            . "\t     [type=flag]\n" . "\n"
            . "  --mode     <auto | off | on>\n"
            . "\t     A word.\n"
            . "\t     [type=word]\n" . "\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "flag variant without value",
                args => [qw(--id flagged --mode)],
                expected => { type => 'flag', id => 'flagged', mode => 1 },
            },
            {
                desc => "flag variant with value",
                args => [qw(--id flagged --mode off)],
                expected => { type => 'flag', id => 'flagged', mode => 0 },
            },
            {
                desc => "flag variant refuses a word that is no boolean",
                args => [qw(--id flagged --mode auto)],
                error => "400 unable to parse boolean option\n",
            },
            {
                desc => "string variant keeps a word that is a boolean too",
                args => [qw(--id worded --mode on)],
                expected => { type => 'word', id => 'worded', mode => 'on' },
            },
            {
                desc => "string variant keeps a word that is no boolean",
                args => [qw(--id worded --mode auto --quiet)],
                expected => { type => 'word', id => 'worded', mode => 'auto' },
                expected_format_options => { quiet => 1 },
            },
            {
                desc => "explicit type takes precedence",
                args => [qw(--id flagged --type word --mode auto)],
                expected => { type => 'word', id => 'flagged', mode => 'auto' },
            },
            {
                desc => "type resolved from a fixed parameter",
                args => [qw(--mode auto)],
                fixed_param => { id => 'worded' },
                expected => { type => 'word', id => 'worded', mode => 'auto' },
            },
            {
                desc => "fixed type takes precedence",
                args => [qw(--id flagged --mode auto)],
                fixed_param => { type => 'word' },
                expected => { type => 'word', id => 'flagged', mode => 'auto' },
            },
        );
    }
}

package OneOfRequiredPerType {
    usebase;

    sub desc($class) {
        'oneOf with parameters that only one variant requires';
    }

    sub schema($class) {
        my $string = sub($description, %rest) {
            return { type => 'string', description => $description, %rest };
        };
        {
            allOf => [
                {
                    additionalProperties => 0,
                    properties => {
                        id => $string->(
                            'The ID, which determines the type.',
                            enum => ['locked', 'open', 'untyped', 'gone'],
                        ),
                    },
                },
                {
                    'type-property' => 'type',
                    'type-property-schema' =>
                        $string->('The type.', enum => ['secret', 'plain']),
                    oneOf => [
                        {
                            'instance-type' => 'secret',
                            additionalProperties => 0,
                            properties => {
                                password => $string->('A password.'),
                                target => $string->('A target.'),
                            },
                        },
                        {
                            'instance-type' => 'plain',
                            additionalProperties => 0,
                            properties => {
                                note => $string->('A note.', optional => 1),
                            },
                        },
                    ],
                },
            ],
        };
    }

    sub additional_method_info($class) {
        return (
            resolve_type => sub {
                my ($param) = @_;
                my $id = $param->{id} // die "no ID given\n";
                die "ID '$id' does not exist\n" if $id eq 'gone';
                return { locked => 'secret', open => 'plain' }->{$id};
            },
        );
    }

    sub usage_param_cb($class) {
        return sub {
            return [{
                name => 'password',
                desc => '<password>',
                func => sub { return $_[0] // 'prompted' },
                interactive => 1,
            }];
        };
    }

    sub long_usage_str($class, $prefix) {
        return undef;
    }

    sub given_usage_strs($class, $prefix) {
        my $arg_param = ['id', 'target'];
        return (
            {
                desc => 'an ID of the type that requires an argument',
                arg_param => $arg_param,
                given => { id => 'locked' },
                expected => "USAGE: $prefix locked <target>\n"
                    . "  <target>   <string>\n"
                    . "\t     A target.\n" . "\n",
            },
            {
                desc => 'an ID of the type without that argument',
                arg_param => $arg_param,
                given => { id => 'open' },
                expected => "USAGE: $prefix open [OPTIONS]\n"
                    . "  --note     <string>\n"
                    . "\t     A note.\n" . "\n",
            },
            {
                desc => 'an ID whose type cannot be resolved',
                arg_param => $arg_param,
                given => { id => 'gone' },
                expected => "USAGE: $prefix <id> <target> [OPTIONS]\n"
                    . "  <id>\t     <gone | locked | open | untyped>\n"
                    . "\t     The ID, which determines the type.\n" . "\n"
                    . "  <target>   <string>\n"
                    . "\t     A target.\n" . "\n"
                    . "  --type     <plain | secret>\n"
                    . "\t     The type.\n" . "\n"
                    . " Conditional options:\n" . "\n"
                    . "  --note     <string>\n"
                    . "\t     A note.\n"
                    . "\t     [type=plain]\n" . "\n",
            },
        );
    }

    sub invocations($class) {
        my $arg_param = ['id', 'target'];
        return (
            {
                desc => "resolved variant has neither the missing argument nor the password",
                args => [qw(open --note text)],
                arg_param => $arg_param,
                expected => { type => 'plain', id => 'open', note => 'text' },
            },
            {
                desc => "fixed variant has neither the missing argument nor the password",
                args => [qw(locked)],
                arg_param => $arg_param,
                fixed_param => { type => 'plain' },
                expected => { type => 'plain', id => 'locked' },
            },
            {
                desc => "resolved variant requires the missing argument",
                args => [qw(locked)],
                arg_param => $arg_param,
                error => "400 not enough arguments\n",
            },
            {
                desc => "resolved variant asks for the password",
                args => [qw(locked there)],
                arg_param => $arg_param,
                expected =>
                    { type => 'secret', id => 'locked', target => 'there', password => 'prompted' },
            },
            {
                desc => "unresolved type falls back to the first variant with the argument",
                args => [qw(untyped)],
                arg_param => $arg_param,
                error => "400 not enough arguments\n",
            },
            {
                desc => "missing arguments are reported before a failure to resolve the type",
                args => [],
                arg_param => $arg_param,
                error => "400 not enough arguments\n",
            },
            {
                desc => "failure to resolve the type",
                args => [qw(gone there)],
                arg_param => $arg_param,
                error => "ID 'gone' does not exist\n",
            },
        );
    }
}

package FixedSecondTypeProperty {
    usebase;

    sub desc($class) {
        'two oneOf with a type property each, the second one fixed';
    }

    sub schema($class) {
        my $typed = sub($type_property, %properties) {
            return {
                'type-property' => $type_property,
                'type-property-schema' => {
                    type => 'string',
                    description => "The $type_property.",
                    enum => [sort keys %properties],
                },
                oneOf => [
                    map { {
                        'instance-type' => $_,
                        additionalProperties => 0,
                        properties => $properties{$_},
                    } } sort keys %properties
                ],
            };
        };
        my $opt = sub($type) {
            return { opt => { optional => 1, type => $type, description => "A $type." } };
        };
        return {
            allOf => [
                $typed->('type', a => {}, b => {}),
                $typed->('mode', flag => $opt->('boolean'), word => $opt->('string')),
            ],
        };
    }

    sub long_usage_str($class, $prefix) {
        return undef;
    }

    sub invocations($class) {
        return (
            {
                desc => "string variant keeps a word",
                args => [qw(--type a --opt text)],
                fixed_param => { mode => 'word' },
                expected => { type => 'a', mode => 'word', opt => 'text' },
            },
            {
                desc => "flag variant without value",
                args => [qw(--type a --opt)],
                fixed_param => { mode => 'flag' },
                expected => { type => 'a', mode => 'flag', opt => 1 },
            },
        );
    }
}

package OneOfSharedOptions {
    usebase;

    sub desc($class) {
        'oneOf with options shared by some or all variants';
    }

    sub schema($class) {
        my $everywhere = { type => 'string', description => 'For all types.' };
        my $anywhere = { optional => 1, type => 'string', description => 'Optional for all.' };
        my $partly = { type => 'string', description => 'Required for some.' };
        my $shared = { optional => 1, type => 'string', description => 'For some types.' };
        return {
            'type-property' => 'type',
            'type-property-schema' => {
                type => 'string',
                description => 'The type.',
                enum => ['one', 'two', 'three'],
            },
            oneOf => [
                {
                    'instance-type' => 'one',
                    additionalProperties => 0,
                    properties => {
                        anywhere => $anywhere,
                        everywhere => $everywhere,
                        partly => $partly,
                        shared => $shared,
                        differs =>
                            { optional => 1, type => 'boolean', description => 'A flag.' },
                    },
                },
                {
                    'instance-type' => 'two',
                    additionalProperties => 0,
                    properties => {
                        anywhere => $anywhere,
                        everywhere => $everywhere,
                        partly => $partly,
                        differs =>
                            { optional => 1, type => 'string', description => 'A word.' },
                        own => { optional => 1, type => 'integer', description => 'For two.' },
                    },
                },
                {
                    'instance-type' => 'three',
                    additionalProperties => 0,
                    properties => {
                        anywhere => $anywhere,
                        everywhere => $everywhere,
                        partly => { $partly->%*, optional => 1 },
                        shared => $shared,
                        differs =>
                            { optional => 1, type => 'string', description => 'A word.' },
                    },
                },
            ],
        };
    }

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix --everywhere <string> --type <string> [OPTIONS]\n"
            . "  --anywhere <string>\n"
            . "\t     Optional for all.\n" . "\n"
            . "  --everywhere <string>\n"
            . "\t     For all types.\n" . "\n"
            . "  --partly   <string>\n"
            . "\t     Required for some.\n" . "\n"
            . "  --type     <one | three | two>\n"
            . "\t     The type.\n" . "\n"
            . " Conditional options:\n" . "\n"
            . "  --differs  <boolean>\n"
            . "\t     A flag.\n"
            . "\t     [type=one]\n" . "\n"
            . "  --differs  <string>\n"
            . "\t     A word.\n"
            . "\t     [type=three, two]\n" . "\n"
            . "  --own      <integer>\n"
            . "\t     For two.\n"
            . "\t     [type=two]\n" . "\n"
            . "  --shared   <string>\n"
            . "\t     For some types.\n"
            . "\t     [type=one, three]\n" . "\n";
    }

    sub asciidoc_usage_str($class, $prefix) {
        "[[cli_test_OneOfSharedOptions]]\n"
            . "*$prefix* `--everywhere <string> --type <string>` `[OPTIONS]`\n"
            . "`--anywhere` `<string>` ::\n\n"
            . "Optional for all.\n\n"
            . "`--everywhere` `<string>` ::\n\n"
            . "For all types.\n\n"
            . "`--partly` `<string>` ::\n\n"
            . "Required for some.\n\n"
            . "`--type` `<one | three | two>` ::\n\n"
            . "The type.\n\n"
            . "\n\n\n`Conditional options:`\n\n"
            . "`--differs` `<boolean>` ::\n\n"
            . "A flag.\n+\n`[type=one]`\n\n"
            . "`--differs` `<string>` ::\n\n"
            . "A word.\n+\n`[type=three, two]`\n\n"
            . "`--own` `<integer>` ::\n\n"
            . "For two.\n+\n`[type=two]`\n\n"
            . "`--shared` `<string>` ::\n\n"
            . "For some types.\n+\n`[type=one, three]`\n\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "option of some types",
                args => [qw(--type three --shared foo --everywhere bar)],
                expected => { type => 'three', shared => 'foo', everywhere => 'bar' },
            },
        );
    }
}

package TwoTypedOneOfs {
    usebase;

    sub desc($class) {
        'two oneOf with a type property each';
    }

    sub schema($class) {
        my $shared = { optional => 1, type => 'string', description => 'For all types.' };
        my $typed = sub($type_property, %properties) {
            return {
                'type-property' => $type_property,
                'type-property-schema' => {
                    type => 'string',
                    description => "The $type_property.",
                    enum => [sort keys %properties],
                },
                oneOf => [
                    map { {
                        'instance-type' => $_,
                        additionalProperties => 0,
                        properties => $properties{$_},
                    } } sort keys %properties
                ],
            };
        };
        my $own = sub($name) {
            return { optional => 1, type => 'string', description => "For $name." };
        };
        return {
            allOf => [
                $typed->(
                    'type',
                    a => { shared => $shared, 'only-a' => $own->('a') },
                    b => { shared => $shared },
                ),
                $typed->(
                    'mode',
                    x => { shared => $shared },
                    y => { 'only-y' => $own->('y') },
                ),
            ],
        };
    }

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix --mode <string> --type <string> [OPTIONS]\n"
            . "  --mode     <x | y>\n"
            . "\t     The mode.\n" . "\n"
            . "  --shared   <string>\n"
            . "\t     For all types.\n" . "\n"
            . "  --type     <a | b>\n"
            . "\t     The type.\n" . "\n"
            . " Conditional options:\n" . "\n"
            . "  --only-a   <string>\n"
            . "\t     For a.\n"
            . "\t     [type=a]\n" . "\n"
            . "  --only-y   <string>\n"
            . "\t     For y.\n"
            . "\t     [mode=y]\n" . "\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "option of both type properties",
                args => [qw(--type a --mode x --shared foo --only-a bar)],
                expected => { type => 'a', mode => 'x', shared => 'foo', 'only-a' => 'bar' },
            },
        );
    }
}

package LegacyInstanceTypes {
    usebase;

    sub desc($class) {
        "properties with 'instance-types'";
    }

    sub schema($class) {
        {
            additionalProperties => 0,
            properties => {
                type => {
                    type => 'string',
                    description => 'The type.',
                    enum => ['one', 'two'],
                },
                both => {
                    optional => 1,
                    type => 'string',
                    description => 'For both types.',
                    'type-property' => 'type',
                    'instance-types' => ['one', 'two'],
                },
                single => {
                    optional => 1,
                    type => 'string',
                    description => 'For one type.',
                    'type-property' => 'type',
                    'instance-types' => ['one'],
                },
            },
        };
    }

    sub long_usage_str($class, $prefix) {
        "USAGE: $prefix --type <string> [OPTIONS]\n"
            . "  --both     <string>\n"
            . "\t     For both types.\n" . "\n"
            . "  --type     <one | two>\n"
            . "\t     The type.\n" . "\n"
            . " Conditional options:\n" . "\n"
            . "  --single   <string>\n"
            . "\t     For one type.\n"
            . "\t     [type=one]\n" . "\n";
    }

    sub invocations($class) {
        return (
            {
                desc => "option of one type",
                args => [qw(--type one --single foo --both bar)],
                expected => { type => 'one', single => 'foo', both => 'bar' },
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
            . "  --flag1    <boolean>\n"
            . "\t     required flag\n"
            . "\t     [type=one]\n" . "\n"
            . "  --flag2    <boolean>\n"
            . "\t     optional flag\n"
            . "\t     [type=two]\n" . "\n"
            . "  --prop-one <a | b>\n"
            . "\t     a or b\n"
            . "\t     [type=one]\n" . "\n"
            . "  --prop-two <number> (3 - 100)\n"
            . "\t     number\n"
            . "\t     [type=two]\n" . "\n";
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
                    'flag1' => 'property is missing and it is not optional',
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
                    'prop-two' => 'property is missing and it is not optional',
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
            . "  --prop-one <string>\n"
            . "\t     a string\n"
            . "\t     [type=one]\n" . "\n"
            . "  --prop-two <number>\n"
            . "\t     number\n"
            . "\t     [type=two]\n" . "\n";
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
            . "  --inner-type <inner1 | inner2>\n"
            . "\t     Inner type.\n"
            . "\t     [type=two]\n" . "\n"
            . "  --prop-inner <string>\n"
            . "\t     an inner string\n"
            . "\t     [type=two and inner-type=inner1]\n" . "\n"
            . "  --prop-inner <number>\n"
            . "\t     an inner number\n"
            . "\t     [type=two and inner-type=inner2]\n" . "\n"
            . "  --prop-one <string>\n"
            . "\t     a string\n"
            . "\t     [type=one]\n" . "\n"
            . "  --prop-two <number>\n"
            . "\t     number\n"
            . "\t     [type=two]\n" . "\n";
    }

    sub given_usage_strs($class, $prefix) {
        return (
            {
                desc => 'the outer type given',
                given => { type => 'two' },
                expected => "USAGE: $prefix"
                    . " --inner-type <string> --prop-two <number> --type two [OPTIONS]\n"
                    . "  --inner-type <inner1 | inner2>\n"
                    . "\t     Inner type.\n" . "\n"
                    . "  --prop-two <number>\n"
                    . "\t     number\n" . "\n"
                    . " Conditional options:\n" . "\n"
                    . "  --prop-inner <string>\n"
                    . "\t     an inner string\n"
                    . "\t     [inner-type=inner1]\n" . "\n"
                    . "  --prop-inner <number>\n"
                    . "\t     an inner number\n"
                    . "\t     [inner-type=inner2]\n" . "\n",
            },
        );
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
        "USAGE: $prefix --common <string> --type <string> [OPTIONS]\n"
            . "  --common   <string>\n"
            . "\t     A common string.\n" . "\n"
            . "  --type     <one | two>\n"
            . "\t     Section Type\n" . "\n"
            . " Conditional options:\n" . "\n"
            . "  --prop-one <string>\n"
            . "\t     A string for type one.\n"
            . "\t     [type=one]\n" . "\n"
            . "  --prop-two <string>\n"
            . "\t     A string for type two.\n"
            . "\t     [type=two]\n" . "\n";
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
            . "  --common   <string>\n"
            . "\t     A common string.\n" . "\n"
            . "  --delete   <string>\n"
            . "\t     A list of settings you want to delete.\n" . "\n"
            . "  --digest   <string>\n"
            . "\t     Prevent changes if current configuration file has a different\n"
            . "\t     digest. This can be used to prevent concurrent modifications.\n" . "\n"
            . "  --type     <one | two>\n"
            . "\t     Section Type\n" . "\n"
            . " Conditional options:\n" . "\n"
            . "  --prop-one <string>\n"
            . "\t     A string for type one.\n"
            . "\t     [type=one]\n" . "\n"
            . "  --prop-two <string>\n"
            . "\t     A string for type two.\n"
            . "\t     [type=two]\n" . "\n";
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
