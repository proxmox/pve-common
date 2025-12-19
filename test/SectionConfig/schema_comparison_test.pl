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

use Storable qw(dclone);

use Test::More;

use SectionConfig::Helpers qw(
    symbol_table_has
    get_subpackages
    get_plugin_system_within_package
    dump_symbol_table
);

package TestPackage {
    use Carp qw(confess);

    sub desc($class) {
        return undef;
    }

    sub expected_unified_createSchema($class) {
        confess "not implemented";
    }

    sub expected_unified_updateSchema($class) {
        confess "not implemented";
    }

    sub expected_isolated_createSchema($class) {
        confess "not implemented";
    }

    sub expected_isolated_updateSchema($class) {
        confess "not implemented";
    }
};

package OneOptionalNoCommon {
    use base qw(TestPackage);

    sub desc($class) {
        return "properties added by plugins are always optional, "
            . "even if they're marked as required";
    }

    package OneOptionalNoCommon::PluginBase {
        use base qw(PVE::SectionConfig);

        my $DEFAULT_DATA = {};

        sub private($class) {
            return $DEFAULT_DATA;
        }
    };

    package OneOptionalNoCommon::PluginOne {
        use base qw(OneOptionalNoCommon::PluginBase);

        sub type($class) {
            return 'one';
        }

        sub properties($class) {
            return {
                'prop-one' => {
                    type => 'string',
                    optional => 0,
                },
            };
        }

        sub options($class) {
            return {
                'prop-one' => {
                    optional => 0,
                },
            };
        }
    };

    package OneOptionalNoCommon::PluginTwo {
        use base qw(OneOptionalNoCommon::PluginBase);

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
                'prop-two' => {
                    optional => 1,
                },
            };
        }
    };

    sub expected_unified_createSchema($class) {
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

    sub expected_unified_updateSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
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
                $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
            },
        };
    }
};

package OneOptionalAllFixedNoCommon {
    use base qw(TestPackage);

    sub desc($class) {
        return "for both unified and isolated mode, fixed properties are not"
            . " included in updateSchema";
    }

    package OneOptionalAllFixedNoCommon::PluginBase {
        use base qw(PVE::SectionConfig);

        my $DEFAULT_DATA = {};

        sub private($class) {
            return $DEFAULT_DATA;
        }
    };

    package OneOptionalAllFixedNoCommon::PluginOne {
        use base qw(OneOptionalAllFixedNoCommon::PluginBase);

        sub type($class) {
            return 'one';
        }

        sub properties($class) {
            return {
                'prop-one' => {
                    type => 'string',
                    optional => 0,
                },
            };
        }

        sub options($class) {
            return {
                'prop-one' => {
                    optional => 0,
                    fixed => 1,
                },
            };
        }
    };

    package OneOptionalAllFixedNoCommon::PluginTwo {
        use base qw(OneOptionalAllFixedNoCommon::PluginBase);

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
                'prop-two' => {
                    optional => 1,
                    fixed => 1,
                },
            };
        }
    };

    sub expected_unified_createSchema($class) {
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

    sub expected_unified_updateSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
            },
        };
    }

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
                $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
            },
        };
    }
};

package AllUnusedNoCommon {
    use base qw(TestPackage);

    sub desc($class) {
        return
            "in unified mode, properties that plugins define but"
            . " do not declare in options() are *not* included in updateSchema"
            . " - in isolated mode, these properties are however included";
    }

    package AllUnusedNoCommon::PluginBase {
        use base qw(PVE::SectionConfig);

        my $DEFAULT_DATA = {};

        sub private($class) {
            return $DEFAULT_DATA;
        }
    };

    package AllUnusedNoCommon::PluginOne {
        use base qw(AllUnusedNoCommon::PluginBase);

        sub type($class) {
            return 'one';
        }

        sub properties($class) {
            return {
                'prop-one' => {
                    type => 'string',
                    optional => 0,
                },
            };
        }

        sub options($class) {
            return {};
        }
    };

    package AllUnusedNoCommon::PluginTwo {
        use base qw(AllUnusedNoCommon::PluginBase);

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
            return {};
        }
    };

    sub expected_unified_createSchema($class) {
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

    sub expected_unified_updateSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
            },
        };
    }

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
                $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
            },
        };
    }
}

package OptionalCommonUnused {
    use base qw(TestPackage);

    sub desc($class) {
        return
            "in unified mode, optional default properties that plugins"
            . " do not declare in options() are *not* included in updateSchema"
            . " - in isolated mode, such properties are included, however";
    }

    package OptionalCommonUnused::PluginBase {
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

    package OptionalCommonUnused::PluginOne {
        use base qw(OptionalCommonUnused::PluginBase);

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

    package OptionalCommonUnused::PluginTwo {
        use base qw(OptionalCommonUnused::PluginBase);

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
                'prop-two' => {
                    optional => 1,
                },
            };
        }
    };

    sub expected_unified_createSchema($class) {
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
                'common' => {
                    type => 'string',
                    optional => 1,
                },
            },
        };
    }

    sub expected_unified_updateSchema($class) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
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
                'common' => {
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

    my $original_private_data = dclone($base->private());

    # unified mode

    for my $plugin ($plugins->@*) {
        $plugin->register();
    }

    $base->init();

    test_compare_deeply(
        $base->createSchema(),
        $package->expected_unified_createSchema(),
        "unified - createSchema comparison",
        $package,
    );

    test_compare_deeply(
        $base->updateSchema(),
        $package->expected_unified_updateSchema(),
        "unified - updateSchema comparison",
        $package,
    );

    # Reset private data so that we can just re-initialize the entire
    # plugin architecture ad hoc
    $base->private()->%* = $original_private_data->%*;

    # isolated mode

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
        if ($package->isa('TestPackage') && $package !~ m/TestPackage/) {
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
