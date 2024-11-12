=head1 NAME

C<PVE::SectionConfig> - An Extendible Configuration File Format

=head1 DESCRIPTION

This package provides a way to have multiple (often similar) types of entries
in the same config file, each in its own section, thus I<Section Config>.

For each C<SectionConfig>-based config file, a C<PVE::JSONSchema> is derived
automatically. This schema can be used to implement CRUD operations for
the config data.

The location of a config file is chosen by the author of the code that uses
C<SectionConfig> and is not something this module is concerned with.

=head1 USAGE

The intended structure is to have a single I<base plugin> that uses the
C<L<PVE::SectionConfig>> module as a base module. Furthermore, it should provide
meaningful defaults in its C<$defaultData>, such as a default list of core
C<L<PVE::JSONSchema>> I<properties>. The I<base plugin> is thus very similar to an
I<abstract class>.

Each I<child plugin> is then defined in its own package that should inherit
from the base plugin and defines which properties it itself provides and
uses, as well as which properties it uses from the base plugin.

The methods that need to be implemented are annotated in the L</METHODS> section
below.

              ┌─────────────────┐
              │  SectionConfig  │
              └────────┬────────┘
                       │
                       │
                       │
              ┌────────▼────────┐
              │    BasePlugin   │
              └────────┬────────┘
                       │
             ┌─────────┴─────────┐
             │                   │
    ┌────────▼────────┐ ┌────────▼────────┐
    │ConcretePluginFoo│ │ConcretePluginBar│
    └─────────────────┘ └─────────────────┘

=head2 REGISTERING PLUGINS

In order to actually be able to use plugins, they must first be
L<< registered|/$plugin->register() >> and then L<< initialized|/$base->init() >>
via the I<base plugin>:

    use PVE::Example::BasePlugin;
    use PVE::Example::PluginA;
    use PVE::Example::PluginB;

    PVE::Example::PluginA->register();
    PVE::Example::PluginB->register();
    PVE::Example::BasePlugin->init();

=head2 MODES

There are two modes for how properties are exposed.

=head3 unified mode (default)

In this mode there is only a global list of properties which the child
plugins can use. This has the consequence that it's not possible to define the
same property name more than once in different plugins.

The reason behind this behaviour is to ensure that properties with the same
name don't behave in different ways, or in other words, to enforce the use of
identical properties for multiple plugins.

=head3 isolated mode

This mode can be used by calling C<L<< init()|/$base->init() >>> with an additional parameter:

    PVE::Example::BasePlugin->init(property_isolation => 1);

With this mode each I<child plugin> gets its own isolated list of properties,
or in other words, a fully isolated schema namespace. Normally one wants to use
C<oneOf> schemas when enabling isolation.

Note that in this mode it's only necessary to specify a property in the
return value of the C<L<< options()|/options() >>> method when it's either
C<fixed> or stems from the global list of properties.

All I<locally> defined properties of a child plugin are automatically added to
its schema.

=cut

package PVE::SectionConfig;

use strict;
use warnings;

use Carp;
use Digest::SHA;

use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools;

=head2 METHODS

=cut

my $defaultData = {
    options => {},
    plugins => {},
    plugindata => {},
    propertyList => {},
};

=head3 $base->private()

B<REQUIRED:> Must be implemented in the I<base plugin>.

    $data = PVE::Example::Plugin->private()
    $data = $class->private()

Returns the entire internal state of C<L<PVE::SectionConfig>>, where all plugins
as well as their C<L<< options()|/$plugin->options() >>> and more are being tracked.

More precisely, this method returns a hash with the following structure:

    {
	propertyList => {
	    'some-optional-property' => {
		type => 'string',
		optional => 1,
		description => 'example property',
	    },
	    some-property => {
		description => 'another example property',
		type => 'boolean'
	    },
	},
	options => {
	    foo => {
		'some-optional-property' => { optional => 1 },
		...
	    },
	    ...
	},
	plugins => {
	    foo => 'PVE::Example::FooPlugin',  # reference to package of child plugin
	    ...
	},
	plugindata => {
	    foo => { ... },  # depends on the specific plugin architecture
	},
    }

Where C<foo> is the C<L<< type()|/$plugin->type() >>> of the plugin. See
C<L<< options()|/$plugin->options() >>> and C<L<< plugindata()|/$plugin->plugindata() >>>
for more information on their corresponding keys above.

Most commonly this is used to define the default I<property list> of one's
plugin architecture upfront, for example:

    use PVE::JSONSchema qw(get_standard_option);

    use base qw(PVE::SectionConfig);

    # [...]

    my $defaultData = {
	propertyList => {
	    type => {
		description => "Type of plugin."
	    },
	    nodes => get_standard_option('pve-node-list', {
		description => "List of nodes for which the plugin applies.",
		optional => 1,
	    }),
	    disable => {
		description => "Flag to disable the plugin.",
		type => 'boolean',
		optional => 1,
	    },
	    'max-foo-rate' => {
		description => "Maximum 'foo' rate of the plugin. Use '-1' for unlimited.",
		type => 'integer',
		minimum => -1,
		default => 42,
		optional => 1,
	    },
	    # [...]
	},
    };

    sub private {
	return $defaultData;
    }

Additional properties defined in I<child plugins> are stored in the
C<propertyList> key. See C<L<< properties()|/$plugin->properties() >>>.

=cut

sub private {
    die "overwrite me";
    return $defaultData;
}

=head3 $plugin->register()

    PVE::Example::Plugin->register()

Used to register I<child plugins>.

More specifically, I<registering> a child plugin means that it is added to the
list of known child plugins that is kept in the hash returned by
C<L<< private()|/$base->private() >>>. Furthermore, the data returned by
C<L<< plugindata()|/$plugin->plugindata() >>> is also stored upon registration.

This method must be called on each child plugin before L<< initializing|/$base->init() >>
the base plugin.

For example:

    use PVE::Example::BasePlugin;
    use PVE::Example::PluginA;
    use PVE::Example::PluginB;

    PVE::Example::PluginA->register();
    PVE::Example::PluginB->register();
    PVE::Example::BasePlugin->init();

=cut

sub register {
    my ($class) = @_;

    my $type = $class->type();
    my $pdata = $class->private();

    die "duplicate plugin registration (type = $type)"
	if defined($pdata->{plugins}->{$type});

    my $plugindata = $class->plugindata();
    $pdata->{plugindata}->{$type} = $plugindata;
    $pdata->{plugins}->{$type} = $class;
}

=head3 $plugin->type()

B<REQUIRED:> Must be implemented in I<B<each>> I<child plugin>.

    $type = PVE::Example::Plugin->type()
    $type = $class->type()

Returns the I<type> of a child plugin, which is a I<unique> string used to
identify the child plugin.

Must be overridden on I<B<each>> I<child plugin>, for example:

    sub type {
	return "foo";
    }

=cut

sub type {
    die "overwrite me";
}

=head3 $plugin->properties()

B<OPTIONAL:> Can be overridden in I<child plugins>.

    $props = PVE::Example::Plugin->properties()
    $props = $class->properties()

Used to register additional properties that belong to a I<child plugin>.
See below for details on L<the different modes|/MODES>.

This method doesn't need to be overridden if no new properties are necessary.

    sub properties() {
	return {
	    path => {
		description => "Path used to retrieve a 'foo'.",
		type => 'string',
		format => 'some-custom-format-handler-for-paths',
	    },
	    is_bar = {
		description => "Whether the 'foo' is 'bar' or not.",
		type => 'boolean',
	    },
	    bwlimit => get_standard_option('bwlimit'),
	};
    }

In the default I<L<unified mode|/MODES>>, these properties are added to the
global list of properties. This means they may also be used by other plugins,
rather than just by itself. The same property must not be defined by other
plugins.

In I<L<isolated mode|/MODES>>, these properties are specific to the plugin
itself and cannot be used by others. They are however automatically added to
the plugin's schema and made C<optional> by default.

See the C<L<< options()|/$plugin->options() >>> method for more information.

=cut

sub properties {
    return {};
}

=head3 $plugin->options()

B<OPTIONAL:> Can be overridden in I<child plugins>.

    $opts = PVE::Example::Plugin->options()
    $opts = $class->options()

This method is used to specify which properties are actually allowed for
a given I<child plugin>. See below for details on L<the different modes|/MODES>.

Additionally, this method also allows to declare whether a property is
C<optional> or C<fixed>.

    sub options {
	return {
	    'some-optional-property' => { optional => 1 },
	    'a-fixed-property' => { fixed => 1 },
	    'a-required-but-not-fixed-property' => {},
	};
    }

C<optional> properties are not required to be set.

C<fixed> properties may only be set on creation of the config entity.

In I<L<unified mode|/MODES>> (default), it is necessary to explicitly specify
which I<properties> are used in the method's return value. Because properties
are registered globally in this mode, any properties may be specified,
regardless of which plugin introduced them.

In I<L<isolated mode|/MODES>>, the locally defined properties (those registered
by overriding C<L<< properties()|/$plugin->properties() >>>) are automatically
added to the plugin's schema and made C<optional> by default. Should this not be
desired, a property may still be explicitly defined, in order to make it required
or C<fixed> instead.

Properties in the global list of properties (see C<L<< private()|/$base->private() >>>)
are not automatically added and must be explicitly defined instead.

=cut

sub options {
    return {};
}

=head3 $plugin->plugindata()

B<OPTIONAL:> Can be implemented in I<child plugins>.

    $plugindata = PVE::Example::Plugin->plugindata()
    $plugindata = $class->plugindata()

This method is used by plugin authors to provide any kind of data specific to
their plugin implementation and is otherwise not touched by C<L<PVE::SectionConfig>>.

This mostly exists for convenience and doesn't need to be implemented.

=cut

sub plugindata {
    return {};
}

=head3 $plugin->has_isolated_properties()

    $is_isolated = PVE::Example::Plugin->has_isolated_properties()
    $is_isolated = $class->has_isolated_properties()

Checks whether the plugin has I<isolated properties> (runs in isolated mode).

=cut

sub has_isolated_properties {
    my ($class) = @_;

    my $isolatedPropertyList = $class->private()->{isolatedPropertyList};

    return defined($isolatedPropertyList) && scalar(keys $isolatedPropertyList->%*) > 0;
}

my sub compare_property {
    my ($a, $b, $skip_opts) = @_;

    my $merged = {$a->%*, $b->%*};
    delete $merged->{$_} for $skip_opts->@*;

    for my $opt (keys $merged->%*) {
	return 0 if !PVE::Tools::is_deeply($a->{$opt}, $b->{$opt});
    }

    return 1;
};

my sub add_property {
    my ($props, $key, $prop, $type) = @_;

    if (!defined($props->{$key})) {
	$props->{$key} = $prop;
	return;
    }

    if (!defined($props->{$key}->{oneOf})) {
	if (compare_property($props->{$key}, $prop, ['instance-types'])) {
	    push $props->{$key}->{'instance-types'}->@*, $type;
	} else {
	    my $new_prop = delete $props->{$key};
	    delete $new_prop->{'type-property'};
	    delete $prop->{'type-property'};
	    $props->{$key} = {
		'type-property' => 'type',
		oneOf => [
		    $new_prop,
		    $prop,
		],
	    };
	}
    } else {
	for my $existing_prop ($props->{$key}->{oneOf}->@*) {
	    if (compare_property($existing_prop, $prop, ['instance-types', 'type-property'])) {
		push $existing_prop->{'instance-types'}->@*, $type;
		return;
	    }
	}

	push $props->{$key}->{oneOf}->@*, $prop;
    }
};

=head3 $plugin->createSchema()

=head3 $plugin->createSchema([ $skip_type, $base ])

    $schema = PVE::Example::Plugin->($skip_type, $base)
    $schema = $class->($skip_type, $base)

Returns the C<PVE::JSONSchema> used for I<creating> config entries of a
I<child plugin>.

This schema may then be used as desired, for example as the definition of
parameters of an API handler (C<POST>).

=over

=item C<$skip_type> (optional)

Can be set to C<1> to not add the C<type> property to the schema.

=item C<$base> (optional)

The schema of additional properties not derived from the plugin definition.

=back

=cut

sub createSchema {
    my ($class, $skip_type, $base) = @_;

    my $pdata = $class->private();
    my $propertyList = $pdata->{propertyList};
    my $plugins = $pdata->{plugins};

    my $props = $base || {};

    if (!$class->has_isolated_properties()) {
	for my $p (keys $propertyList->%*) {
	    next if $skip_type && $p eq 'type';

	    if (!$propertyList->{$p}->{optional}) {
		$props->{$p} = $propertyList->{$p};
		next;
	    }

	    my $required = 1;

	    my $copts = $class->options();
	    $required = 0 if defined($copts->{$p}) && $copts->{$p}->{optional};

	    for my $t (keys $plugins->%*) {
		my $opts = $pdata->{options}->{$t} || {};
		$required = 0 if !defined($opts->{$p}) || $opts->{$p}->{optional};
	    }

	    if ($required) {
		# make a copy, because we modify the optional property
		my $res = {$propertyList->{$p}->%*}; # shallow copy
		$res->{optional} = 0;
		$props->{$p} = $res;
	    } else {
		$props->{$p} = $propertyList->{$p};
	    }
	}
    } else {
	for my $type (sort keys $plugins->%*) {
	    my $opts = $pdata->{options}->{$type} || {};
	    for my $key (sort keys $opts->%*) {
		my $schema = $class->get_property_schema($type, $key);
		my $prop = {$schema->%*};
		$prop->{'instance-types'} = [$type];
		$prop->{'type-property'} = 'type';
		$prop->{optional} = 1 if $opts->{$key}->{optional};

		add_property($props, $key, $prop, $type);
	    }
	}
	# add remaining global properties
	for my $opt (keys $propertyList->%*) {
	    next if $props->{$opt};
	    $props->{$opt} = {$propertyList->{$opt}->%*};
	}
	for my $opt (keys $props->%*) {
	    if (my $necessaryTypes = $props->{$opt}->{'instance-types'}) {
		if ($necessaryTypes->@* == scalar(keys $plugins->%*)) {
		    delete $props->{$opt}->{'instance-types'};
		    delete $props->{$opt}->{'type-property'};
		} else {
		    $props->{$opt}->{optional} = 1;
		}
	    }
	}
    }

    return {
	type => "object",
	additionalProperties => 0,
	properties => $props,
    };
}

=head3 $plugin->updateSchema()

=head3 $plugin->updateSchema([ $single_class, $base ])

    $updated_schema = PVE::Example::Plugin->($single_class, $base)
    $updated_schema = $class->updateSchema($single_class, $base)

Returns the C<L<PVE::JSONSchema>> used for I<updating> config entries of a
I<child plugin>.

This schema may then be used as desired, for example as the definition of
parameters of an API handler (C<PUT>).

=over

=item C<$single_class> (optional)

Can be set to C<1> to only include properties which are defined in the returned
hash of C<L<< options()|/options() >>> of the plugin C<$class>.

This parameter is only valid for child plugins, not the base plugin.

=item C<$base> (optional)

The schema of additional properties not derived from the plugin definition.

=back

=cut

sub updateSchema {
    my ($class, $single_class, $base) = @_;

    my $pdata = $class->private();
    my $propertyList = $pdata->{propertyList};
    my $plugins = $pdata->{plugins};

    my $props = $base || {};

    my $filter_type = $single_class ? $class->type() : undef;

    if (!$class->has_isolated_properties()) {
	for my $p (keys $propertyList->%*) {
	    next if $p eq 'type';

	    my $copts = $class->options();

	    next if defined($filter_type) && !defined($copts->{$p});

	    if (!$propertyList->{$p}->{optional}) {
		$props->{$p} = $propertyList->{$p};
		next;
	    }

	    my $modifiable = 0;

	    $modifiable = 1 if defined($copts->{$p}) && !$copts->{$p}->{fixed};

	    for my $t (keys $plugins->%*) {
		my $opts = $pdata->{options}->{$t} || {};
		next if !defined($opts->{$p});
		$modifiable = 1 if !$opts->{$p}->{fixed};
	    }
	    next if !$modifiable;

	    $props->{$p} = $propertyList->{$p};
	}
    } else {
	for my $type (sort keys $plugins->%*) {
	    my $opts = $pdata->{options}->{$type} || {};
	    for my $key (sort keys $opts->%*) {
		next if $opts->{$key}->{fixed};

		my $schema = $class->get_property_schema($type, $key);
		my $prop = {$schema->%*};
		$prop->{'instance-types'} = [$type];
		$prop->{'type-property'} = 'type';
		$prop->{optional} = 1;

		add_property($props, $key, $prop, $type);
	    }
	}

	for my $opt (keys $propertyList->%*) {
	    next if $props->{$opt};
	    $props->{$opt} = {$propertyList->{$opt}->%*};
	}

	for my $opt (keys $props->%*) {
	    if (my $necessaryTypes = $props->{$opt}->{'instance-types'}) {
		if ($necessaryTypes->@* == scalar(keys $plugins->%*)) {
		    delete $props->{$opt}->{'instance-types'};
		    delete $props->{$opt}->{'type-property'};
		}
	    }
	}
    }

    $props->{digest} = get_standard_option('pve-config-digest');

    $props->{delete} = {
	type => 'string', format => 'pve-configid-list',
	description => "A list of settings you want to delete.",
	maxLength => 4096,
	optional => 1,
    };

    return {
	type => "object",
	additionalProperties => 0,
	properties => $props,
    };
}

=head3 $base->init()

=head3 $base->init(property_isolation => 1)

    $base_plugin->init();
    $base_plugin->init(property_isolation => 1);

This method is used to initialize C<SectionConfig> using all of the
I<child plugins> that were I<L<< registered|/$plugin->register() >>> beforehand.

Optionally, it is also possible to pass C<< property_isolation => 1>> to C<%param>
in order to activate I<isolated mode>. See L</MODES> in the package-level
documentation for more information.

=cut

sub init {
    my ($class, %param) = @_;

    my $property_isolation = $param{property_isolation};

    my $pdata = $class->private();

    for my $k (qw(options plugins plugindata propertyList isolatedPropertyList)) {
	$pdata->{$k} = {} if !$pdata->{$k};
    }

    my $plugins = $pdata->{plugins};
    my $propertyList = $pdata->{propertyList};
    my $isolatedPropertyList = $pdata->{isolatedPropertyList};

    for my $type (keys $plugins->%*) {
	my $props = $plugins->{$type}->properties();
	for my $p (keys $props->%*) {
	    my $res;
	    if ($property_isolation) {
		$res = $isolatedPropertyList->{$type}->{$p} = {};
	    } else {
		die "duplicate property '$p'" if defined($propertyList->{$p});
		$res = $propertyList->{$p} = {};
	    }
	    my $data = $props->{$p};
	    for my $a (keys $data->%*) {
		$res->{$a} = $data->{$a};
	    }
	    $res->{optional} = 1;
	}
    }

    for my $type (keys $plugins->%*) {
	my $opts = $plugins->{$type}->options();
	for my $p (keys $opts->%*) {
	    my $prop;
	    if ($property_isolation) {
		$prop = $isolatedPropertyList->{$type}->{$p};
	    }
	    $prop //= $propertyList->{$p};
	    die "undefined property '$p'" if !$prop;
	}

	# automatically the properties to options (if not specified explicitly)
	if ($property_isolation) {
	    for my $p (keys $isolatedPropertyList->{$type}->%*) {
		next if $opts->{$p};
		$opts->{$p} = {};
		$opts->{$p}->{optional} = 1 if $isolatedPropertyList->{$type}->{$p}->{optional};
	    }
	}

	$pdata->{options}->{$type} = $opts;
    }

    $propertyList->{type}->{type} = 'string';
    $propertyList->{type}->{enum} = [sort keys $plugins->%*];
}

=head3 $base->lookup($type)

    $plugin = PVE::Example::BasePlugin->lookup($type)
    $plugin = $class->lookup($type)

Returns the I<child plugin> corresponding to the given C<L<< type()|/$plugin->type() >>>
or dies if it cannot be found.

=cut

sub lookup {
    my ($class, $type) = @_;

    croak "cannot lookup undefined type!" if !defined($type);

    my $pdata = $class->private();
    my $plugin = $pdata->{plugins}->{$type};

    die "unknown section type '$type'\n" if !$plugin;

    return $plugin;
}

=head3 $base->lookup_types()

    $types = PVE::Example::BasePlugin->lookup_types()
    $types = $class->lookup_types()

Returns a list of all I<child plugin> C<L<< type|/$plugin->type() >>>s.

=cut

sub lookup_types {
    my ($class) = @_;

    my $pdata = $class->private();

    return [ sort keys %{$pdata->{plugins}} ];
}

=head3 $base->decode_value(...)

=head3 $base->decode_value($type, $key, $value)

B<OPTIONAL:> Can be implemented in the I<base plugin>.

    $decoded_value = PVE::Example::BasePlugin->decode_value($type, $key, $value)
    $decoded_value = $class->($type, $key, $value)

Called during C<L<< check_config()|/$base->check_config(...) >>> in order to convert values
that have been read from a C<L<PVE::SectionConfig>> file which have been
I<encoded> beforehand by C<L<< encode_value()|/$base->encode_value(...) >>>.

Does nothing to C<$value> by default, but can be overridden in the I<base plugin>
in order to implement custom conversion behavior.

    sub decode_value {
	my ($class, $type, $key, $value) = @_;

	if ($key eq 'nodes') {
	    my $res = {};

	    for my $node (PVE::Tools::split_list($value)) {
		if (PVE::JSONSchema::pve_verify_node_name($node)) {
		    $res->{$node} = 1;
		}
	    }

	    return $res;
	}

	return $value;
    }

=over

=item C<$type>

The C<L<< type()|/$plugin->type() >>> of plugin the C<$key> and C<$value> belong to.

=item C<$key>

The name of a I<L<< property|/$plugin->properties() >> that has been set on a C<$type> of
config section.

=item C<$value>

The raw value of the I<L<< property|/$plugin->properties >>> denoted by C<$key> that was read
from a section config file.

=back

=cut

sub decode_value {
    my ($class, $type, $key, $value) = @_;

    return $value;
}

=head3 $base->encode_value(...)

=head3 $base->encode_value($type, $key, $value)

B<OPTIONAL:> Can be implemented in the I<base plugin>.

    $encoded_value = PVE::Example::BasePlugin->encode_value($type, $key, $value)
    $encoded_value = $class->($type, $key, $value)

Called during C<L<< write_config()|/$base->write_config(...) >>> in order to
convert values into a serializable format.

Does nothing to C<$value> by default, but can be overridden in the I<base plugin>
in order to implement custom conversion behavior. Usually one should also
override C<L<< decode_value()|/$base->decode_value(...) >>> in a matching manner.

    sub encode_value {
	my ($class, $type, $key, $value) = @_;

	if ($key eq 'nodes') {
	    return join(',', keys(%$value));
	}

	return $value;
    }

=over

=item C<$type>

The C<L<< type()|/$plugin->type() >>> of plugin the C<$key> and C<$value> belong to.

=item C<$key>

The name of a I<L<< property|/$plugin->properties() >>> that has been set on a
C<$type> of config section.

=item C<$value>

The value of the I<L<< property|/$plugin->properties >>> denoted by C<$key> to be
encoded so that it can be written to a section config file.

=back

=cut

sub encode_value {
    my ($class, $type, $key, $value) = @_;

    return $value;
}

=head3 $base->check_value(...)

=head3 $base->check_value($type, $key, $value, $storeid [, $skipSchemaCheck ])

    $checked_value = PVE::Example::BasePlugin->check_value($type, $key, $value, $storeid, $skipSchemaCheck)
    $checked_value = $class->check_value($type, $key, $value, $storeid, $skipSchemaCheck)

Used internally to check if various invariants are upheld when parsing a section
config file. Also performs a C<PVE::JSONSchema> check on the C<$value> of the
I<property> given by C<$key> of the plugin C<$type>, unless C<$skipSchemaCheck>
is truthy.

=over

=item C<$type>

The C<L<< type()|/$plugin->type() >>> of plugin the C<$key> and C<$value> belong to.

=item C<$key>

The name of a I<L<< property|/$plugin->properties() >>> that has been set on a
C<$type> of config section.

=item C<$value>

The value of the I<L<< property|/$plugin->properties() >>> denoted by C<$key>
that was read from a section config file.

=item C<$storeid>

The identifier of a section, as returned by C<L<< parse_section_header()|/$base->parse_section_header(...) >>>.

=item C<$skipSchemaCheck> (optional)

Whether to skip performing a C<L<PVE::JSONSchema>> property check on the given
C<$value>.

=back

=cut

sub check_value {
    my ($class, $type, $key, $value, $storeid, $skipSchemaCheck) = @_;

    my $pdata = $class->private();

    return $value if $key eq 'type' && $type eq $value;

    my $opts = $pdata->{options}->{$type};
    die "unknown section type '$type'\n" if !$opts;

    die "unexpected property '$key'\n" if !defined($opts->{$key});

    my $schema = $class->get_property_schema($type, $key);
    die "unknown property type\n" if !$schema;

    my $ct = $schema->{type};

    $value = 1 if $ct eq 'boolean' && !defined($value);

    die "got undefined value\n" if !defined($value);

    die "property contains a line feed\n" if $value =~ m/[\n\r]/;

    if (!$skipSchemaCheck) {
	my $errors = {};

	my $checkschema = $schema;

	if ($ct eq 'array') {
	    die "no item schema for array" if !defined($schema->{items});
	    $checkschema = $schema->{items};
	}

	PVE::JSONSchema::check_prop($value, $checkschema, '', $errors);
	if (scalar(keys $errors->%*)) {
	    die "$errors->{$key}\n" if $errors->{$key};
	    die "$errors->{_root}\n" if $errors->{_root};
	    die "unknown error\n";
	}
    }

    if ($ct eq 'boolean' || $ct eq 'integer' || $ct eq 'number') {
	return $value + 0; # convert to number
    }

    return $value;
}

=head3 $base->parse_section_header($line)

B<OPTIONAL:> Can be overridden in the I<base plugin>.

    ($type, $sectionId, $errmsg, $config) = PVE::Example::BasePlugin->parse_section_header($line)
    ($type, $sectionId, $errmsg, $config) = $class->parse_section_header($line)

Parses the header of a section and returns an array containing the section's
L<< type|/$plugin->type() >>, ID and optionally an error message as well as
additional config attributes.

Can be overridden on the I<base plugin> in order to provide custom logic for
handling the header, e.g. if the section IDs need to be parsed or validated in
a certain way.

For example:

    sub parse_section_header {
	my ($class, $line) = @_;

	if ($line =~ m/^(\S):\s*(\S+)\s*$/) {
	    my ($type, $sectionId) = ($1, $2);

	    my $errmsg = undef;
	    eval { check_section_id_is_valid($sectionId); };
	    $errmsg = $@ if $@;

	    my $config = parse_extra_stuff_from_section_id($sectionId);

	    return ($type, $sectionId, $errmsg, $config);
	}
	return undef;
    }

=cut

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
	my ($type, $sectionId) = ($1, $2);
	my $errmsg = undef; # set if you want to skip whole section
	my $config = {}; # to return additional attributes
	return ($type, $sectionId, $errmsg, $config);
    }
    return undef;
}

=head3 $base->format_section_header(...)

=head3 $base->format_section_header($type, $sectionId, $scfg, $done_hash)

B<OPTIONAL:> Can be overridden in the I<base plugin>.

    $header = PVE::Example::BasePlugin->format_section_header($type, $sectionId, $scfg, $done_hash)
    $header = $class->format_section_header($type, $sectionId, $scfg, $done_hash)

Formats the header of a section. Simply C<"$type: $sectionId\n"> by default.

Note that when overriding this, the header B<MUST> end with a newline (C<\n>).
One also might want to add a matching override for
C<L<< parse_section_header()|/$base->parse_section_header($line) >>>.

=cut

sub format_section_header {
    my ($class, $type, $sectionId, $scfg, $done_hash) = @_;

    return "$type: $sectionId\n";
}

=head3 $base->get_property_schema(...)

=head3 $base->get_property_schema($type, $key)

    $schema = PVE::Example::BasePlugin->get_property_schema($type, $key)
    $schema = $class->get_property_schema($type, $key)

Returns the schema of the L<< property|/$plugin->properties() >> C<$key> of the
plugin for C<$type>.

=cut

sub get_property_schema {
    my ($class, $type, $key) = @_;

    my $pdata = $class->private();
    my $opts = $pdata->{options}->{$type};

    my $schema;
    if ($class->has_isolated_properties()) {
	$schema = $pdata->{isolatedPropertyList}->{$type}->{$key};
    }
    $schema //= $pdata->{propertyList}->{$key};

    return $schema;
}

=head3 $base->parse_config(...)

=head3 $base->parse_config($filename, $raw [, $allow_unknown ])

    $config = PVE::Example::BasePlugin->parse_config($filename, $raw, $allow_unknown)
    $config = $class->parse_config($filename, $raw, $allow_unknown)

Parses the contents of a file as C<L<PVE::SectionConfig>>, returning the parsed
data annotated with additional information (see below).

=over

=item C<$filename>

The name of the file whose content is stored in C<$raw>.

Only used for error messages and warnings, so it may also be something else.

=item C<$raw>

The raw content of C<$filename>.

=item C<$allow_unknown> (optional)

Whether to allow parsing unknown I<types>.

=back

The returned hash is structured as follows:

    {
	ids => {
	    foo => {
		key => value,
		...
	    },
	    bar => {
		key => value,
		...
	    },
	},
	order => {
	    foo => 1,
	    bar => 2,
	},
	digest => "5f5513f8822fdbe5145af33b64d8d970dcf95c6e",
	errors => (
	    {
		context => ...,
		section => "section ID",
		key => "some_key",
		err => "error message",
	    },
	    ...
	),
    }

=over

=item C<ids>

Each section's parsed data (via C<L<< check_config()/$base->check_config(...) >>>),
indexed by the section ID.

=item C<order>

The order in which the sections in C<ids> were found in the config file.

=item C<digest>

A SHA1 hex digest of the contents in C<$raw>. May for example be used to check
whether the configuration has changed between parses.

=item C<errors> (optional)

An optional list of error hashes.

=back

The hashes in the optionally returned C<errors> key are structured as follows:

=over

=item C<context>

In which file and in which line the error was encountered.

=item C<section>

In which section the error was encountered.

=item C<key>

Which I<property> the error corresponds to.

=item C<err>

The error.

=back

=cut

sub parse_config {
    my ($class, $filename, $raw, $allow_unknown) = @_;

    my $pdata = $class->private();

    my $ids = {};
    my $order = {};

    $raw = '' if !defined($raw);

    my $digest = Digest::SHA::sha1_hex($raw);

    my $pri = 1;

    my $lineno = 0;
    my @lines = split(/\n/, $raw);
    my $nextline = sub {
	while (defined(my $line = shift @lines)) {
	    $lineno++;
	    return $line if ($line !~ /^\s*#/);
	}
    };

    my $is_array = sub {
	my ($type, $key) = @_;

	my $schema = $class->get_property_schema($type, $key);
	die "unknown property type\n" if !$schema;

	return $schema->{type} eq 'array';
    };

    my $errors = [];
    while (@lines) {
	my $line = $nextline->();
	next if !$line;

	my $errprefix = "file $filename line $lineno";

	my ($type, $sectionId, $errmsg, $config) = $class->parse_section_header($line);
	if ($config) {
	    my $skip = 0;
	    my $unknown = 0;

	    my $plugin;

	    if ($errmsg) {
		$skip = 1;
		chomp $errmsg;
		warn "$errprefix (skip section '$sectionId'): $errmsg\n";
	    } elsif (!$type) {
		$skip = 1;
		warn "$errprefix (skip section '$sectionId'): missing type - internal error\n";
	    } else {
		if (!($plugin = $pdata->{plugins}->{$type})) {
		    if ($allow_unknown) {
			$unknown = 1;
		    } else {
			$skip = 1;
			warn "$errprefix (skip section '$sectionId'): unsupported type '$type'\n";
		    }
		}
	    }

	    while ($line = $nextline->()) {
		next if $skip;

		$errprefix = "file $filename line $lineno";

		if ($line =~ m/^\s+(\S+)(\s+(.*\S))?\s*$/) {
		    my ($k, $v) = ($1, $3);

		    eval {
			if ($unknown) {
			    if (!defined($config->{$k})) {
				$config->{$k} = $v;
			    } else {
				if (!ref($config->{$k})) {
				    $config->{$k} = [$config->{$k}];
				}
				push $config->{$k}->@*, $v;
			    }
			} elsif ($is_array->($type, $k)) {
			    $v = $plugin->check_value($type, $k, $v, $sectionId);
			    $config->{$k} = [] if !defined($config->{$k});
			    push $config->{$k}->@*, $v;
			} else {
			    die "duplicate attribute\n" if defined($config->{$k});
			    $v = $plugin->check_value($type, $k, $v, $sectionId);
			    $config->{$k} = $v;
			}
		    };
		    if (my $err = $@) {
			warn "$errprefix (section '$sectionId') - unable to parse value of '$k': $err";
			push $errors->@*, {
			    context => $errprefix,
			    section => $sectionId,
			    key => $k,
			    err => $err,
			};
		    }

		} else {
		    warn "$errprefix (section '$sectionId') - ignore config line: $line\n";
		}
	    }

	    if ($unknown) {
		$config->{type} = $type;
		$ids->{$sectionId} = $config;
		$order->{$sectionId} = $pri++;
	    } elsif (!$skip && $type && $plugin && $config) {
		$config->{type} = $type;
		if (!$unknown) {
		    $config = eval { $config = $plugin->check_config($sectionId, $config, 1, 1); };
		    warn "$errprefix (skip section '$sectionId'): $@" if $@;
		}
		$ids->{$sectionId} = $config;
		$order->{$sectionId} = $pri++;
	    }

	} else {
	    warn "$errprefix - ignore config line: $line\n";
	}
    }

    my $cfg = {
	ids => $ids,
	order => $order,
	digest => $digest
    };
    $cfg->{errors} = $errors if scalar($errors->@*) > 0;

    return $cfg;
}

=head3 $base->check_config(...)

=head3 $base->check_config($sectionId, $config, $create [, $skipSchemaCheck ])

    $settings = PVE::Example::BasePlugin->check_config($sectionId, $config, $create, $skipSchemaCheck)
    $settings = $class->check_config($sectionId, $config, $create, $skipSchemaCheck)

Does not just check whether a section's configuration is valid, despite its
name, but also calls checks values of I<L<< properties|/$plugin_>properties() >>>
with C<L<< check_value()|/$base->check_value(...) >>> before decoding them using
C<L<< decode_value()|/$base->decode_value(...) >>>.

Returns a hash which contains all I<L<< properties|/$plugin_>properties() >>>
for the given C<$sectionId>. In other words, all configured key-value pairs for
the provided section.

=over

=item C<$sectionId>

The identifier of a section, as returned by C<L<< /$base->parse_section_header($line) >>>.

=item C<$config>

The configuration of the section corresponding to C<$sectionId>.

=item C<$create>

If set to C<1>, checks whether a value has been set for all required properties
of C<$config>.

=item C<$skipSchemaCheck> (optional)

Whether to skip performing any C<L<PVE::JSONSchema>> property checks.

=back

=head4 A Note on Extending and Overriding

If additional checks are needed that cannot be expressed in the schema, this
method may be extended or overridden I<with care>.

When this method is I<overridden>, as in the original implementation is replaced
completely, all values must still be checked via C<L<< check_value()|/$base->check_value(...) >>>
and decoded with C<L<< decode_value()|/$base->decode_value(...) >>>.

When extending the method, as in calling C<L<< $class->SUPER::check_config()|/$base->check_config(...) >>>
inside the redefined method, it is important to note that the contents of the
hash returned by the C<SUPER> call differ from the contents of C<$config>. This
means that a custom check performed I<before> the C<SUPER> call cannot
necessarily be performed in the same way I<after> the C<SUPER> call.

=cut

sub check_config {
    my ($class, $sectionId, $config, $create, $skipSchemaCheck) = @_;

    my $type = $class->type();
    my $pdata = $class->private();
    my $opts = $pdata->{options}->{$type};

    my $settings = { type => $type };

    for my $k (keys $config->%*) {
	my $value = $config->{$k};

	die "can't change value of fixed parameter '$k'\n"
	    if !$create && defined($opts->{$k}) && $opts->{$k}->{fixed};

	if (defined($value)) {
	    my $tmp = $class->check_value($type, $k, $value, $sectionId, $skipSchemaCheck);
	    $settings->{$k} = $class->decode_value($type, $k, $tmp);
	} else {
	    die "got undefined value for option '$k'\n";
	}
    }

    if ($create) {
	# check if we have a value for all required options
	for my $k (keys $opts->%*) {
	    next if $opts->{$k}->{optional};
	    die "missing value for required option '$k'\n"
		if !defined($config->{$k});
	}
    }

    return $settings;
}

my sub format_config_line {
    my ($schema, $key, $value) = @_;

    my $ct = $schema->{type};

    die "property '$key' contains a line feed\n"
	if ($key =~ m/[\n\r]/) || ($value =~ m/[\n\r]/);

    if ($ct eq 'boolean') {
	return "\t$key " . ($value ? 1 : 0) . "\n"
	    if defined($value);
    } elsif ($ct eq 'array') {
	die "property '$key' is not an array" if ref($value) ne 'ARRAY';
	my $result = '';
	for my $line ($value->@*) {
	    $result .= "\t$key $line\n" if $value ne '';
	}
	return $result;
    } else {
	return "\t$key $value\n" if "$value" ne '';
    }
};

=head3 $base->write_config(...)

=head3 $base->write_config($filename, $cfg [, $allow_unknown ])

    $output = PVE::Example::BasePlugin->write_config($filename, $cfg, $allow_unknown)
    $output = $class->write_config($filename, $cfg, $allow_unknown)

Generates the output that should be written to the C<L<PVE::SectionConfig>> file.

=over

=item C<$filename> (unused)

The name of the file to which the generated output will be written to.
This parameter is currently unused and has no effect.

=item C<$cfg>

The hash that represents the entire configuration that should be written.
This hash is expected to have the following format:

    {
	ids => {
	    foo => {
		key => value,
		...
	    },
	    bar => {
		key => value,
		...
	    },
	},
	order => {
	    foo => 1,
	    bar => 2,
	},
    }

Any other top-level keys will be ignored, so it's okay to pass along the
C<digest> key from C<L<< parse_config()|/$base->parse_config(...) >>>, for example.

=item C<$allow_unknown> (optional)

Whether to allow writing sections with an unknown I<L</type>>.

=back

=cut

sub write_config {
    my ($class, $filename, $cfg, $allow_unknown) = @_;

    my $pdata = $class->private();

    my $out = '';

    my $ids = $cfg->{ids};
    my $order = $cfg->{order};

    my $maxpri = 0;
    for my $sectionId (keys $ids->%*) {
	my $pri = $order->{$sectionId};
	$maxpri = $pri if $pri && $pri > $maxpri;
    }
    for my $sectionId (keys $ids->%*) {
	if (!defined ($order->{$sectionId})) {
	    $order->{$sectionId} = ++$maxpri;
	}
    }

    for my $sectionId (sort {$order->{$a} <=> $order->{$b}} keys $ids->%*) {
	my $scfg = $ids->{$sectionId};
	my $type = $scfg->{type};
	my $opts = $pdata->{options}->{$type};
	my $global_opts = $pdata->{options}->{__global};

	die "unknown section type '$type'\n" if !$opts && !$allow_unknown;

	my $done_hash = {};

	my $data = $class->format_section_header($type, $sectionId, $scfg, $done_hash);

	if (!$opts && $allow_unknown) {
	    $done_hash->{type} = 1;
	    my @first = exists($scfg->{comment}) ? ('comment') : ();
	    for my $k (@first, sort keys $scfg->%*) {
		next if defined($done_hash->{$k});
		$done_hash->{$k} = 1;
		my $v = $scfg->{$k};
		my $ref = ref($v);
		if (defined($ref) && $ref eq 'ARRAY') {
		    $data .= "\t$k $_\n" for $v->@*;
		} else {
		    $data .= "\t$k $v\n";
		}
	    }
	    $out .= "$data\n";
	    next;
	}


	if ($scfg->{comment} && !$done_hash->{comment}) {
	    my $k = 'comment';
	    my $v = $class->encode_value($type, $k, $scfg->{$k});
	    my $prop = $class->get_property_schema($type, $k);
	    $data .= format_config_line($prop, $k, $v);
	}

	$data .= "\tdisable\n" if $scfg->{disable} && !$done_hash->{disable};

	$done_hash->{comment} = 1;
	$done_hash->{disable} = 1;

	my @option_keys = sort keys $opts->%*;
	for my $k (@option_keys) {
	    next if defined($done_hash->{$k});
	    next if $opts->{$k}->{optional};
	    $done_hash->{$k} = 1;
	    my $v = $scfg->{$k};
	    die "section '$sectionId' - missing value for required option '$k'\n"
		if !defined ($v);
	    $v = $class->encode_value($type, $k, $v);
	    my $prop = $class->get_property_schema($type, $k);
	    $data .= format_config_line($prop, $k, $v);
	}

	for my $k (@option_keys) {
	    next if defined($done_hash->{$k});
	    my $v = $scfg->{$k};
	    next if !defined($v);
	    $v = $class->encode_value($type, $k, $v);
	    my $prop = $class->get_property_schema($type, $k);
	    $data .= format_config_line($prop, $k, $v);
	}

	$out .= "$data\n";
    }

    return $out;
}

sub assert_if_modified {
    my ($cfg, $digest) = @_;

    PVE::Tools::assert_if_modified($cfg->{digest}, $digest);
}

=head3 delete_from_config(...)

=head3 delete_from_config($config, $option_schema, $new_options, $to_delete)

    $config = delete_from_config($config, $option_schema, $new_options, $to_delete)

Convenience helper method used internally to delete keys from the single section
config C<$config>.

Specifically, the keys given by C<$to_delete> are deleted from C<$config> if
they're not required or fixed, or set in the same go.

Note: The passed C<$config> is modified in place and also returned.

=over

=item C<$config>

The section's configuration that the given I<L<< properties|/$plugin->properties(...) >>>
in C<$to_delete> should be deleted from.

=item C<$option_schema>

The schema of the properties associated with C<$config>. See the
C<L<< options()|/$plugin->options() >>> method.

=item C<$new_options>

The properties which will be added to C<$config>. Note that this method doesn't
add any properties itself; this is to prohibit simultaneously setting and deleting
the same I<property>.

=item C<$to_delete>

A reference to an array containing the names of the properties to delete from
C<$config>.

=back

=cut

sub delete_from_config {
    my ($config, $option_schema, $new_options, $to_delete) = @_;

    for my $k ($to_delete->@*) {
	my $d = $option_schema->{$k} || die "no such option '$k'\n";
	die "unable to delete required option '$k'\n" if !$d->{optional};
	die "unable to delete fixed option '$k'\n" if $d->{fixed};
	die "cannot set and delete property '$k' at the same time!\n"
	    if defined($new_options->{$k});
	delete $config->{$k};
    }

    return $config;
}

1;
