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

my sub base_schema() {
    return {
        'base-prop' => {
            type => 'string',
            optional => 0,
        },
    };
}

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

    sub expected_isolated_schema_base($class, $optional, $single_class) {
        confess "not implemented";
    }

    sub expected_isolated_createSchema($class, $skip_type) {
        return $class->expected_isolated_schema_base(0, undef, $skip_type);
    }

    sub expected_isolated_updateSchema($class, $single_class) {
        my $schema = $class->expected_isolated_schema_base(1, $single_class, 0),
            my $update_prop_schema = {
                additionalProperties => 0,
                properties => { $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%* },
            };
        if ($schema->{allOf}) {
            unshift $schema->{allOf}->@*, $update_prop_schema;
            return $schema;
        } else {
            return {
                allOf => [$update_prop_schema, $schema],
            };
        }
    }
};

package BasicConfig {
    use base qw(TestPackage);

    sub desc($class) {
        return "base parameters passed to the section config should show up "
            . "regardless of whether property isolation is in effect";
    }

    package BasicConfig::PluginBase {
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

    package BasicConfig::PluginOne {
        use base qw(BasicConfig::PluginBase);

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
                common => {
                    optional => 1,
                },
                'prop-one' => {
                    optional => 0,
                },
            };
        }

        sub expected_unified_updateSchema($class) {
            return {
                type => 'object',
                additionalProperties => 0,
                properties => {
                    'base-prop' => {
                        type => 'string',
                        optional => 0,
                    },
                    common => {
                        type => 'string',
                        optional => 1,
                    },
                    'prop-one' => {
                        type => 'string',
                        optional => 1,
                    },
                    $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
                },
            };
        }
    };

    package BasicConfig::PluginTwo {
        use base qw(BasicConfig::PluginBase);

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

        sub expected_unified_updateSchema($class) {
            return {
                type => 'object',
                additionalProperties => 0,
                properties => {
                    'base-prop' => {
                        type => 'string',
                        optional => 0,
                    },
                    common => {
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
    };

    sub expected_unified_createSchema($class, $skip_type) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                $skip_type
                ? ()
                : (
                    type => {
                        type => 'string',
                        enum => [
                            "one", "two",
                        ],
                    },
                ),
                'base-prop' => {
                    type => 'string',
                    optional => 0,
                },
                'common' => {
                    type => 'string',
                    optional => 1,
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

    sub expected_unified_updateSchema($class, $single_class) {
        if (defined($single_class)) {
            return $single_class->expected_unified_updateSchema();
        }

        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                'base-prop' => {
                    type => 'string',
                    optional => 0,
                },
                'common' => {
                    type => 'string',
                    optional => 1,
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

    sub expected_isolated_schema_base($class, $optional, $single_class, $skip_type) {
        die "cannot use 'skip_type' for configs with more than 1 section type\n" if $skip_type;

        my $base = {
            additionalProperties => 0,
            properties => {
                'base-prop' => {
                    type => 'string',
                    optional => 0,
                },
            },
        };
        my $schema_one = {
            additionalProperties => 0,
            properties => {
                'common' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-one' => {
                    type => 'string',
                    optional => $optional,
                },
            },
        };
        my $schema_two = {
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
        };

        if (defined($single_class)) {
            my $schema;
            if ($single_class eq 'main::BasicConfig::PluginOne') {
                return { allOf => [$base, $schema_one] };
            } elsif ($single_class eq 'main::BasicConfig::PluginTwo') {
                return { allOf => [$base, $schema_two] };
            } else {
                die "unexpected test plugin class '$single_class'";
            }
        }
        $schema_one->{'instance-type'} = 'one';
        $schema_two->{'instance-type'} = 'two';

        return {
            allOf => [
                $base,
                {
                    'type-property' => 'type',
                    'type-property-schema' => {
                        type => 'string',
                        description => 'Section Type',
                        enum => [qw(one two)],
                    },
                    oneOf => [$schema_one, $schema_two],
                },
            ],
        };
    }
};

package SingleSection {
    use base qw(TestPackage);

    sub desc($class) {
        return "single-section SectionConfigs may use skip_type in isolation mode";
    }

    package SingleSection::PluginBase {
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

    package SingleSection::PluginOne {
        use base qw(SingleSection::PluginBase);

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
                common => {
                    optional => 1,
                },
                'prop-one' => {
                    optional => 0,
                },
            };
        }

        sub expected_unified_updateSchema($class) {
            return {
                type => 'object',
                additionalProperties => 0,
                properties => {
                    'base-prop' => {
                        type => 'string',
                        optional => 0,
                    },
                    common => {
                        type => 'string',
                        optional => 1,
                    },
                    'prop-one' => {
                        type => 'string',
                        optional => 1,
                    },
                    $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
                },
            };
        }
    };

    sub expected_unified_createSchema($class, $skip_type) {
        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                $skip_type
                ? ()
                : (
                    type => {
                        type => 'string',
                        enum => ["one"],
                    },
                ),
                'base-prop' => {
                    type => 'string',
                    optional => 0,
                },
                'common' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-one' => {
                    type => 'string',
                    optional => 0,
                },
            },
        };
    }

    sub expected_unified_updateSchema($class, $single_class) {
        if (defined($single_class)) {
            return $single_class->expected_unified_updateSchema();
        }

        return {
            type => 'object',
            additionalProperties => 0,
            properties => {
                'base-prop' => {
                    type => 'string',
                    optional => 0,
                },
                'common' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-one' => {
                    type => 'string',
                    optional => 1,
                },
                $SectionConfig::Helpers::UPDATE_SCHEMA_DEFAULT_PROPERTIES->%*,
            },
        };
    }

    sub expected_isolated_schema_base($class, $optional, $single_class, $skip_type) {
        my $base = {
            additionalProperties => 0,
            properties => {
                'base-prop' => {
                    type => 'string',
                    optional => 0,
                },
            },
        };
        my $schema_one = {
            additionalProperties => 0,
            properties => {
                'common' => {
                    type => 'string',
                    optional => 1,
                },
                'prop-one' => {
                    type => 'string',
                    optional => $optional,
                },
            },
        };

        if ($skip_type) {
            return { allOf => [$base, $schema_one] };
        }

        if (defined($single_class)) {
            my $schema;
            if ($single_class eq 'main::SingleSection::PluginOne') {
                return { allOf => [$base, $schema_one] };
            } else {
                die "unexpected test plugin class '$single_class'";
            }
        }
        $schema_one->{'instance-type'} = 'one';

        return {
            allOf => [
                $base,
                {
                    'type-property' => 'type',
                    'type-property-schema' => {
                        type => 'string',
                        description => 'Section Type',
                        enum => ['one'],
                    },
                    oneOf => [$schema_one],
                },
            ],
        };
    }
};

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
        $base->createSchema(0, base_schema()),
        $package->expected_unified_createSchema(0),
        "unified - createSchema comparison, skip_type = false",
        $package,
    );

    test_compare_deeply(
        $base->createSchema(1, base_schema()),
        $package->expected_unified_createSchema(1),
        "unified - createSchema comparison, skip_type = true",
        $package,
    );

    test_compare_deeply(
        $base->updateSchema(0, base_schema()),
        $package->expected_unified_updateSchema(undef),
        "unified - updateSchema comparison",
        $package,
    );

    for my $plugin ($plugins->@*) {
        test_compare_deeply(
            $plugin->updateSchema(1, base_schema()),
            $package->expected_unified_updateSchema($plugin),
            "unified - updateSchema comparison, single_class = '$plugin'",
            $package,
        );
    }

    # Reset private data so that we can just re-initialize the entire
    # plugin architecture ad hoc
    $base->private()->%* = $original_private_data->%*;

    # isolated mode

    for my $plugin ($plugins->@*) {
        $plugin->register();
    }

    $base->private()->{propertyIsolation} = 1;
    $base->init();

    test_compare_deeply(
        $base->createSchema(0, base_schema()),
        $package->expected_isolated_createSchema(0),
        "isolated - createSchema comparison, skip_type = false",
        $package,
    );

    my $got_value = eval { $base->createSchema(1, base_schema()) };
    my $got_error = $@;
    my $expected_value = eval { $package->expected_isolated_createSchema(1) };
    my $expected_error = $@;
    test_compare_deeply(
        $got_value,
        $expected_value,
        "isolated - createSchema comparison, skip_type = true",
        $package,
    );
    is(
        $got_error,
        $expected_error,
        "isolated - createSchema comparison, skip_type = true, expected errors",
    );

    test_compare_deeply(
        $base->updateSchema(0, base_schema()),
        $package->expected_isolated_updateSchema(undef),
        "isolated - updateSchema comparison",
        $package,
    );

    for my $plugin ($plugins->@*) {
        test_compare_deeply(
            $plugin->updateSchema(1, base_schema()),
            $package->expected_isolated_updateSchema($plugin),
            "isolated - updateSchema comparison, single_class = '$plugin'",
            $package,
        );
    }

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
