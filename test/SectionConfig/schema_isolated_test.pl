#!/usr/bin/perl

use v5.36;

use lib qw(
    ..
    ../../src/
);

use Data::Dumper;

$Data::Dumper::Terse = 1;
$Data::Dumper::Indent = 1;
$Data::Dumper::Useqq = 1;
$Data::Dumper::Deparse = 1;
$Data::Dumper::Quotekeys = 0;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Trailingcomma = 1;

use Test::More;

use SectionConfig::Helpers qw(
    symbol_table_has
    get_subpackages
    get_plugin_system_within_package
    dump_symbol_table
);

package TestPackage {
    use Carp qw(confess);

    sub expect_error($class) {
        return;
    }

    sub expected_isolated_schema_base($class, $optional) {
        confess "not implemented";
    }

    sub expected_isolated_createSchema($class) {
        return $class->expected_isolated_schema_base(0);
    }

    sub expected_isolated_updateSchema($class) {
        return {
            allOf => [
                {
                    additionalProperties => 0,
                    properties =>
                        { $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%* },
                },
                $class->expected_isolated_schema_base(1),
            ],
        };
    }

    sub desc($class) {
        return undef;
    }
};

package OptionalCommonRequiredAndOptional {
    use base qw(TestPackage);

    sub desc($class) {
        return
            "optional default properties not required by all plugins"
            . " are optional in both schemas for plugins that use them,"
            . " even if a plugin marks it as required";
    }

    package OptionalCommonRequiredAndOptional::PluginBase {
        use base qw(PVE::SectionConfig);

        my $DEFAULT_DATA = {
            propertyIsolation => 1,
            propertyList => {
                common => {
                    type => 'string',
                    optional => 1,
                },
            },
        };

        sub private($class) {
            return $DEFAULT_DATA;
        }
    };

    package OptionalCommonRequiredAndOptional::PluginOne {
        use base qw(OptionalCommonRequiredAndOptional::PluginBase);

        sub type($class) {
            return 'one';
        }

        sub properties($class) {
            return {
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
            };
        }

        sub options($class) {
            return {
                common => {
                    optional => 0,
                },
                'prop-one' => {
                    optional => 1,
                },
            };
        }
    };

    package OptionalCommonRequiredAndOptional::PluginTwo {
        use base qw(OptionalCommonRequiredAndOptional::PluginBase);

        sub type($class) {
            return 'two';
        }

        sub properties($class) {
            return {
                'prop-two' => {
                    type => 'string',
                    optional => 1,
                },
            };
        }

        sub options($class) {
            return {
                common => {
                    optional => 1,
                },
                'prop-two' => {
                    optional => 1,
                },
            };
        }
    };

    sub expected_isolated_schema_base($class, $optional) {
        return {

            'type-property' => 'type',
            'type-property-schema' => {
                type => 'string',
                description => 'Section Type',
                enum => [qw(one two)],
            },
            oneOf => [
                {
                    'instance-type' => 'one',
                    additionalProperties => 0,
                    properties => {
                        'common' => {
                            type => 'string',
                            optional => 1,
                        },
                        'prop-one' => {
                            type => 'string',
                            optional => 1,
                        },
                    },
                },
                {
                    'instance-type' => 'two',
                    additionalProperties => 0,
                    properties => {
                        'common' => {
                            type => 'string',
                            optional => 1,
                        },
                        'prop-two' => {
                            type => 'string',
                            optional => 1,
                        },
                    },
                },
            ],
        };
    }
}

package RequiredCommonRequiredAndOptional {
    use base qw(TestPackage);

    sub desc($class) {
        return "when a required default property is marked as both optional and required"
            . " by different plugins, 'oneOf' is used in createSchema";
    }

    package RequiredCommonRequiredAndOptional::PluginBase {
        use base qw(PVE::SectionConfig);

        my $DEFAULT_DATA = {
            propertyIsolation => 1,
            propertyList => {
                common => {
                    type => 'string',
                    optional => 0,
                },
            },
        };

        sub private($class) {
            return $DEFAULT_DATA;
        }
    };

    package RequiredCommonRequiredAndOptional::PluginOne {
        use base qw(RequiredCommonRequiredAndOptional::PluginBase);

        sub type($class) {
            return 'one';
        }

        sub properties($class) {
            return {
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
            };
        }

        sub options($class) {
            return {
                common => {
                    optional => 0,
                },
                'prop-one' => {
                    optional => 1,
                },
            };
        }
    };

    package RequiredCommonRequiredAndOptional::PluginTwo {
        use base qw(RequiredCommonRequiredAndOptional::PluginBase);

        sub type($class) {
            return 'two';
        }

        sub properties($class) {
            return {
                'prop-two' => {
                    type => 'string',
                    optional => 1,
                },
            };
        }

        sub options($class) {
            return {
                common => {
                    optional => 1,
                },
                'prop-two' => {
                    optional => 1,
                },
            };
        }
    };

    sub expected_isolated_schema_base($class, $optional) {
        return {
            'type-property' => 'type',
            'type-property-schema' => {
                type => 'string',
                description => 'Section Type',
                enum => [qw(one two)],
            },
            oneOf => [
                {
                    'instance-type' => 'one',
                    additionalProperties => 0,
                    properties => {
                        'common' => {
                            type => 'string',
                            optional => $optional,
                        },
                        'prop-one' => {
                            type => 'string',
                            optional => 1,
                        },
                    },
                },
                {
                    'instance-type' => 'two',
                    additionalProperties => 0,
                    properties => {
                        'common' => {
                            type => 'string',
                            optional => 1,
                        },
                        'prop-two' => {
                            type => 'string',
                            optional => 1,
                        },
                    },
                },
            ],
        };
    }
}

sub test_compare_deeply($got, $expected, $test_name, $test_package) {
    $test_name = "$test_package - $test_name";
    my $description = $test_package->desc();

    if (!is_deeply($got, $expected, $test_name)) {
        note("\nDescription: ", $description // "(none)", "\n");
        note("Got:");
        note(Dumper($got));
        note("Expected:");
        note(Dumper($expected));
        note("=" x 40);
    }

    return;
}

sub init_and_run_tests($package) {
    my $system = get_plugin_system_within_package($package);

    my ($base, $plugins) = $system->@{qw(base plugins)};

    eval {
        for my $plugin ($plugins->@*) {
            $plugin->register();
        }

        $base->init();
    };
    my $err = $@;
    my $expected_err = $package->expect_error();
    if ($expected_err) {
        if (!$err) {
            fail("'$package' expects an error, but succeeded to initialize");
        } else {
            my $substr = $err && substr($err, 0, length($expected_err));
            ok($substr eq $expected_err, "'$package' expects a specific error")
                or diag("Got error: $err\nExpected error: $expected_err\n");
        }
    } elsif ($err) {
        fail("'$package' expected no errors - $err");
    }

    #<<<
    SKIP: {
    #>>>
        skip "'$package' is supposed to fail initialization", 2 if $err || $expected_err;

        test_compare_deeply(
            $base->createSchema(),
            $package->expected_isolated_createSchema(),
            "isolated - createSchema comparison",
            $package,
        );

        test_compare_deeply(
            $base->updateSchema(),
            $package->expected_isolated_updateSchema(),
            "isolated - updateSchema comparison",
            $package,
        );
    }

    return;
}

sub main() {
    my $subpackages = get_subpackages('main');

    my $test_packages = [];

    for my $package (sort $subpackages->@*) {
        if ($package !~ m/TestPackage/ && $package->isa('TestPackage')) {
            push($test_packages->@*, $package);
        }
    }

    for my $package ($test_packages->@*) {
        init_and_run_tests($package);
    }

    done_testing();

    return 0;
}

main();
