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

    sub expected_isolated_createSchema($class) {
        confess "not implemented";
    }

    sub expected_isolated_updateSchema($class) {
        confess "not implemented";
    }

    sub desc($class) {
        return undef;
    }
};

package IdenticalPropertiesOnDifferentPlugins {
    use base qw(TestPackage);

    sub desc($class) {
        return "defining identical properties on different plugins does not lead to"
            . " 'oneOf' being used inside either createSchema or updateSchema";
    }

    package IdenticalPropertiesOnDifferentPlugins::PluginBase {
        use base qw(PVE::SectionConfig);

        my $DEFAULT_DATA = {};

        sub private($class) {
            return $DEFAULT_DATA;
        }
    };

    package IdenticalPropertiesOnDifferentPlugins::PluginOne {
        use base qw(IdenticalPropertiesOnDifferentPlugins::PluginBase);

        sub type($class) {
            return 'one';
        }

        sub properties($class) {
            return {
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    type => 'string',
                    optional => 1,
                },
            };
        }

        sub options($class) {
            return {
                'prop-one' => {
                    optional => 1,
                },
                'prop-two' => {
                    optional => 1,
                },
            };
        }
    };

    package IdenticalPropertiesOnDifferentPlugins::PluginTwo {
        use base qw(IdenticalPropertiesOnDifferentPlugins::PluginBase);

        sub type($class) {
            return 'two';
        }

        sub properties($class) {
            return {
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    type => 'string',
                    optional => 1,
                },
            };
        }

        sub options($class) {
            return {
                'prop-one' => {
                    optional => 1,
                },
                'prop-two' => {
                    optional => 1,
                },
            };
        }
    };

    sub expected_isolated_createSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                type => {
                    type => 'string',
                    enum => [
                        "one", "two",
                    ],
                },
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    type => 'string',
                    optional => 1,
                },
            },
        };
    }

    sub expected_isolated_updateSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                type => {
                    type => 'string',
                    enum => [
                        "one", "two",
                    ],
                },
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    type => 'string',
                    optional => 1,
                },
                $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
            },
        };
    }
}

package IdenticalPropertyOnDifferentPlugin {
    use base qw(TestPackage);

    sub desc($class) {
        return "defining identical properties on different plugins does not lead to"
            . " 'oneOf' being used inside either createSchema or updateSchema";
    }

    package IdenticalPropertyOnDifferentPlugin::PluginBase {
        use base qw(PVE::SectionConfig);

        my $DEFAULT_DATA = {};

        sub private($class) {
            return $DEFAULT_DATA;
        }
    };

    package IdenticalPropertyOnDifferentPlugin::PluginOne {
        use base qw(IdenticalPropertyOnDifferentPlugin::PluginBase);

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
                'prop-one' => {
                    optional => 1,
                },
            };
        }
    };

    package IdenticalPropertyOnDifferentPlugin::PluginTwo {
        use base qw(IdenticalPropertyOnDifferentPlugin::PluginBase);

        sub type($class) {
            return 'two';
        }

        sub properties($class) {
            return {
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    type => 'string',
                    optional => 1,
                },
            };
        }

        sub options($class) {
            return {
                'prop-one' => {
                    optional => 1,
                },
                'prop-two' => {
                    optional => 1,
                },
            };
        }
    };

    sub expected_isolated_createSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                type => {
                    type => 'string',
                    enum => [
                        "one", "two",
                    ],
                },
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    'instance-types' => [
                        "two",
                    ],
                    'type-property' => 'type',
                    type => 'string',
                    optional => 1,
                },
            },
        };
    }

    sub expected_isolated_updateSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                type => {
                    type => 'string',
                    enum => [
                        "one", "two",
                    ],
                },
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    'instance-types' => [
                        "two",
                    ],
                    'type-property' => 'type',
                    type => 'string',
                    optional => 1,
                },
                $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
            },
        };
    }
}

package SamePropertyNamesOnDifferentPlugins {
    use base qw(TestPackage);

    sub desc($class) {
        return
            "defining properties with the same name but different optionality"
            . " on different plugins does not lead to 'oneOf' being used inside"
            . " either createSchema or updateSchema - because properties defined"
            . " by plugins are always marked as optional";
    }

    package SamePropertyNamesOnDifferentPlugins::PluginBase {
        use base qw(PVE::SectionConfig);

        my $DEFAULT_DATA = {};

        sub private($class) {
            return $DEFAULT_DATA;
        }
    };

    package SamePropertyNamesOnDifferentPlugins::PluginOne {
        use base qw(SamePropertyNamesOnDifferentPlugins::PluginBase);

        sub type($class) {
            return 'one';
        }

        sub properties($class) {
            return {
                'prop-one' => {
                    type => 'string',
                    optional => 0,
                },
                'prop-two' => {
                    type => 'string',
                    optional => 1,
                },
            };
        }

        sub options($class) {
            return {
                'prop-one' => {
                    optional => 0,
                },
                'prop-two' => {
                    optional => 1,
                },
            };
        }
    };

    package SamePropertyNamesOnDifferentPlugins::PluginTwo {
        use base qw(SamePropertyNamesOnDifferentPlugins::PluginBase);

        sub type($class) {
            return 'two';
        }

        sub properties($class) {
            return {
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    type => 'string',
                    optional => 0,
                },
            };
        }

        sub options($class) {
            return {
                'prop-one' => {
                    optional => 1,
                },
                'prop-two' => {
                    optional => 0,
                },
            };
        }
    };

    sub expected_isolated_createSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                type => {
                    type => 'string',
                    enum => [
                        "one", "two",
                    ],
                },
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    type => 'string',
                    optional => 1,
                },
            },
        };
    }

    sub expected_isolated_updateSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                type => {
                    type => 'string',
                    enum => [
                        "one", "two",
                    ],
                },
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    type => 'string',
                    optional => 1,
                },
                $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
            },
        };
    }
}

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

    sub expected_isolated_createSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                type => {
                    type => 'string',
                    enum => [
                        "one", "two",
                    ],
                },
                'prop-one' => {
                    'instance-types' => [
                        "one",
                    ],
                    'type-property' => 'type',
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    'instance-types' => [
                        "two",
                    ],
                    'type-property' => 'type',
                    type => 'string',
                    optional => 1,
                },
                'common' => {
                    type => 'string',
                    optional => 1,
                },
            },
        };
    }

    sub expected_isolated_updateSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                type => {
                    type => 'string',
                    enum => [
                        "one", "two",
                    ],
                },
                'prop-one' => {
                    'instance-types' => [
                        "one",
                    ],
                    'type-property' => 'type',
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    'instance-types' => [
                        "two",
                    ],
                    'type-property' => 'type',
                    type => 'string',
                    optional => 1,
                },
                common => {
                    type => 'string',
                    optional => 1,
                },
                $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
            },
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

    sub expected_isolated_createSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                type => {
                    type => 'string',
                    enum => [
                        "one", "two",
                    ],
                },
                'prop-one' => {
                    'instance-types' => [
                        "one",
                    ],
                    'type-property' => 'type',
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    'instance-types' => [
                        "two",
                    ],
                    'type-property' => 'type',
                    type => 'string',
                    optional => 1,
                },
                'common' => {
                    oneOf => [
                        {
                            'instance-types' => [
                                "one",
                            ],
                            optional => 0,
                            type => 'string',
                        },
                        {
                            'instance-types' => [
                                "two",
                            ],
                            optional => 1,
                            type => 'string',
                        },
                    ],
                    'type-property' => 'type',
                },
            },
        };
    }

    sub expected_isolated_updateSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                type => {
                    type => 'string',
                    enum => [
                        "one", "two",
                    ],
                },
                'prop-one' => {
                    'instance-types' => [
                        "one",
                    ],
                    'type-property' => 'type',
                    type => 'string',
                    optional => 1,
                },
                'prop-two' => {
                    'instance-types' => [
                        "two",
                    ],
                    'type-property' => 'type',
                    type => 'string',
                    optional => 1,
                },
                common => {
                    type => 'string',
                    optional => 1,
                },
                $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
            },
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

    for my $plugin ($plugins->@*) {
        $plugin->register();
    }

    $base->init(property_isolation => 1);

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
