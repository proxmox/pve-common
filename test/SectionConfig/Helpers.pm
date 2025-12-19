package SectionConfig::Helpers;

use v5.36;

use Data::Dumper;

$Data::Dumper::Terse = 1;
$Data::Dumper::Indent = 1;
$Data::Dumper::Useqq = 1;
$Data::Dumper::Deparse = 1;
$Data::Dumper::Quotekeys = 0;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Trailingcomma = 1;

use base qw(Exporter);

our @EXPORT_OK = qw(
    get_symbol_table
    symbol_table_has
    get_subpackages
    get_plugin_system_within_package
    dump_symbol_table
);

our $UPDATE_SCHEMA_DEFAULT_PROPERTIES = {
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

sub get_symbol_table($package) {
    my $symbols = eval {
        no strict 'refs'; ## no critic (ProhibitNoStrict)
        *package_glob = *{"${package}::"};
        my %syms = *package_glob->%*;
        \%syms;
    };

    return $symbols;
}

sub symbol_table_has($package, $ref) {
    my $symbols = get_symbol_table($package);
    return defined($symbols->{$ref});
}

sub get_subpackages($package) {
    my $symbols = get_symbol_table($package);

    my $subpackages = [];

    for my $symbol (keys $symbols->%*) {
        if ($symbol =~ m/(?<name>.*)::$/) {
            my $name = $+{name};
            my $subpackage = "${package}::${name}";

            my $is_class = eval { $subpackage->isa('UNIVERSAL') } || '';

            push($subpackages->@*, $subpackage) if $is_class;
        }
    }

    return $subpackages;
}

sub get_plugin_system_within_package($package) {
    my $subpackages = get_subpackages($package);

    my $base = undef;
    my $plugins = [];

    for my $package ($subpackages->@*) {
        if ($package->isa('PVE::SectionConfig') && symbol_table_has($package, 'private')) {
            $base = $package;
            last;
        }
    }

    for my $package ($subpackages->@*) {
        if ($package->isa($base) && symbol_table_has($package, 'type')) {
            push($plugins->@*, $package);
        }
    }

    if (!defined($base)) {
        die "failed to get plugin system within package '$package'";
    }

    return {
        base => $base,
        plugins => $plugins,
    };
}

# debug aid
sub dump_symbol_table($package) {
    my $symbols = get_symbol_table($package);
    print("'$package' => ", Dumper($symbols), "\n");
    return;
}

1;
