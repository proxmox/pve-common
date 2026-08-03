#!/usr/bin/perl

# `init()` is called at module scope by the modules using a section config, so two of them
# pulling in the same config initializes it twice in one process. Check that this works and
# yields the same schemas, in all three modes.

use v5.36;

use lib qw(../../src);

use Test::More;

use PVE::SectionConfig;
use PVE::Tools;

my sub make_config($name, $base_data, $plugin_data) {
    no strict 'refs'; ## no critic
    my $base = "${name}::Base";
    push @{"${base}::ISA"}, 'PVE::SectionConfig';
    my $data = { propertyList => { id => { type => 'string' } }, $base_data->%* };
    *{"${base}::private"} = sub { return $data };

    for my $type (sort keys $plugin_data->%*) {
        my $plugin = "${name}::" . ucfirst($type);
        push @{"${plugin}::ISA"}, $base;
        *{"${plugin}::type"} = sub { return $type };
        *{"${plugin}::plugindata"} = sub { return $plugin_data->{$type} };
        *{"${plugin}::properties"} = sub {
            return { "prop-$type" => { type => 'string', optional => 1 } };
        };
        *{"${plugin}::options"} = sub { return { "prop-$type" => { optional => 1 } } };
        $plugin->register();
    }

    return $base;
}

my $configs = [
    ['unified', {}, { one => {}, two => {} }],
    ['isolated', { propertyIsolation => 1 }, { one => {}, two => {} }],
    [
        'partially-isolated',
        {},
        { one => { 'isolate-properties' => 1, 'expose-properties' => 1 }, two => {} },
    ],
];

for my $config ($configs->@*) {
    my ($name, $base_data, $plugin_data) = $config->@*;

    my $base = make_config($name, $base_data, $plugin_data);

    eval { $base->init() };
    is($@, '', "$name - first init");
    my $create = $base->createSchema();
    my $update = $base->updateSchema();

    eval { $base->init() };
    is($@, '', "$name - second init");

    is_deeply($base->createSchema(), $create, "$name - create schema is stable");
    is_deeply($base->updateSchema(), $update, "$name - update schema is stable");
}

done_testing();
