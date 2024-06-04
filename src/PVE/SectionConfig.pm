package PVE::SectionConfig;

use strict;
use warnings;

use Carp;
use Digest::SHA;

use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools;

=pod

=head1 NAME

SectionConfig

=head1 DESCRIPTION

This package provides a way to have multiple (often similar) types of entries
in the same config file, each in its own section, thus I<Section Config>.

Under the hood, this package automatically creates and manages a matching
I<JSONSchema> for one's plugin architecture that is used to represent data
that is read from and written to the config file.

Where this config file is located, as well as its permissions and other related
things, is up to the plugin author and is not handled by C<PVE::SectionConfig>
at all.

=head1 USAGE

The intended structure is to have a single I<base plugin> that inherits from
this class and provides meaningful defaults in its C<$defaultData>, such as a
default list of core C<PVE::JSONSchema> I<properties>. The I<base plugin> is
thus very similar to an I<abstract class>.

Each I<child plugin> is then defined in its own package that should inherit
from the I<base plugin> and defines which I<properties> it itself provides and
uses, as well as which I<properties> it uses from the I<base plugin>.

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

In order to actually be able to use plugins, they must first be I<registered>
and then I<initialized> via the "base" plugin:

    use PVE::Example::BasePlugin;
    use PVE::Example::PluginA;
    use PVE::Example::PluginB;

    PVE::Example::PluginA->register();
    PVE::Example::PluginB->register();
    PVE::Example::BasePlugin->init();

=head2 MODES

There are two modes for how I<properties> are exposed.

=head3 unified mode (default)

In this mode there is only a global list of I<properties> which the child
plugins can use. This has the consequence that it's not possible to define the
same property name more than once in different plugins.

The reason behind this behaviour is to ensure that properties with the same
name don't behave in different ways, or in other words, to enforce the use of
identical properties for multiple plugins.

=head3 isolated mode

This mode can be used by calling C<init> with an additional parameter:

    PVE::Example::BasePlugin->init(property_isolation => 1);

With this mode each I<child plugin> gets its own isolated list of I<properties>,
or in other words, a fully isolated schema namespace. Normally one wants to use
C<oneOf> schemas when enabling isolation.

Note that in this mode it's only necessary to specify a I<property> in the
C<options> method when it's either C<fixed> or stems from the global list of
I<properties>.

All locally defined I<properties> of a I<child plugin> are automatically added
to its schema.

=head2 METHODS

=cut

my $defaultData = {
    options => {},
    plugins => {},
    plugindata => {},
    propertyList => {},
};

=pod

=head3 private

B<REQUIRED:> Must be implemented in the I<base plugin>.

    $data = PVE::Example::Plugin->private()
    $data = $class->private()

Getter for C<SectionConfig>-related private data.

Most commonly this is used to simply retrieve the default I<property> list of
one's plugin architecture, for example:

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

=cut

sub private {
    die "overwrite me";
    return $defaultData;
}

=pod

=head3 register

    PVE::Example::Plugin->register()

Used to register I<child plugins>.

This method must be called on each child plugin before I<initializing> the base
plugin.

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

=pod

=head3 type

B<REQUIRED:> Must be implemented in I<child plugins>.

    $type = PVE::Example::Plugin->type()
    $type = $class->type()

Returns the I<type> of a I<child plugin>, which is a I<unique> string. This is
used to identify the I<child plugin>.

Should be overridden on I<child plugins>:

    sub type {
	return "foo";
    }

=cut

sub type {
    die "overwrite me";
}

=pod

=head3 properties

B<REQUIRED:> Must be implemented in I<child plugins>.

    $props = PVE::Example::Plugin->properties()
    $props = $class->properties()

Returns the I<properties> specific to a I<child plugin> as a hash.

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

=cut

sub properties {
    return {};
}

=pod

=head3 options

B<REQUIRED:> Must be implemented in I<child plugins>.

    $opts = PVE::Example::Plugin->options()
    $opts = $class->options()

This method is used to specify which I<properties> are actually configured for
a given I<child plugin>. More precisely, only the I<properties> that are
contained in the hash this method returns can be used.

Additionally, it also allows to declare whether a property is C<optional> or
C<fixed>.

    sub options {
	return {
	    'some-optional-property' => { optional => 1 },
	    'a-fixed-property' => { fixed => 1 },
	    'a-required-but-not-fixed-property' => {},
	};
    }

C<optional> I<properties> are not required to be set.

C<fixed> I<properties> may only be set on creation of the config entity.

=cut

sub options {
    return {};
}

=pod

=head3 plugindata

B<OPTIONAL:> Can be implemented in I<child plugins>.

    $plugindata = PVE::Example::Plugin->plugindata()
    $plugindata = $class->plugindata()

This method is used by plugin authors to provide any kind of data specific to
their plugin implementation and is otherwise not touched by C<SectionConfig>.

This mostly exists for convenience and doesn't need to be implemented.

=cut

sub plugindata {
    return {};
}

=pod

=head3 has_isolated_properties

    $is_isolated = PVE::Example::Plugin->has_isolated_properties()
    $is_isolated = $class->has_isolated_properties()

Checks whether the plugin has isolated I<properties> (runs in isolated mode).

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

=pod

=head3 createSchema

    $schema = PVE::Example::Plugin->($skip_type, $base)
    $schema = $class->($skip_type, $base)

Returns the C<PVE::JSONSchema> used for I<creating> instances of a
I<child plugin>.

This schema may then be used as desired, for example as the definition of
parameters of an API handler (C<POST>).

=over

=item C<$skip_type> (optional)

Can be set to C<1> if there's a I<property> named "type" in the list of
default I<properties> that should be excluded from the generated schema.

=item C<$base> (optional)

The I<properties> to use per default.

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

=pod

=head3 updateSchema

Returns the C<PVE::JSONSchema> used for I<updating> instances of a
I<child plugin>.

This schema may then be used as desired, for example as the definition of
parameters of an API handler (C<PUT>).

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

	    my $modifyable = 0;

	    $modifyable = 1 if defined($copts->{$p}) && !$copts->{$p}->{fixed};

	    for my $t (keys $plugins->%*) {
		my $opts = $pdata->{options}->{$t} || {};
		next if !defined($opts->{$p});
		$modifyable = 1 if !$opts->{$p}->{fixed};
	    }
	    next if !$modifyable;

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

=pod

=head3 init

    $base_plugin->init();
    $base_plugin->init(property_isolation => 1);

This method is used to initialize all I<child plugins> that have been
I<registered> beforehand.

Optionally, it is also possible to pass C<property_isolation> as parameter in
order to activate I<isolated mode>. See L</MODES> in the package-level
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

=pod

=head3 lookup

    $plugin = PVE::Example::BasePlugin->lookup($type)
    $plugin = $class->lookup($type)

Returns the I<child plugin> corresponding to the given C<type> or dies if it
cannot be found.

=cut

sub lookup {
    my ($class, $type) = @_;

    croak "cannot lookup undefined type!" if !defined($type);

    my $pdata = $class->private();
    my $plugin = $pdata->{plugins}->{$type};

    die "unknown section type '$type'\n" if !$plugin;

    return $plugin;
}

=pod

=head3 lookup_types

    $types = PVE::Example::BasePlugin->lookup_types()
    $types = $class->lookup_types()

Returns a list of all I<child plugins'> C<type>s.

=cut

sub lookup_types {
    my ($class) = @_;

    my $pdata = $class->private();

    return [ sort keys %{$pdata->{plugins}} ];
}

=pod

=head3 decode_value

B<OPTIONAL:> Can be implemented in the I<base plugin>.

    $decoded_value = PVE::Example::BasePlugin->decode_value($type, $key, $value)
    $decoded_value = $class->($type, $key, $value)

Called during C<check_config> in order to convert values that have been read
from a C<SectionConfig> file which have been I<encoded> beforehand by
C<encode_value>.

Does nothing to C<$value> by default, but can be overridden in the I<base plugin>
in order to implement custom conversion behavior.

=cut

sub decode_value {
    my ($class, $type, $key, $value) = @_;

    return $value;
}

=pod

=head3 encode_value

B<OPTIONAL:> Can be implemented in the I<base plugin>.

    $encoded_value = PVE::Example::BasePlugin->encode_value($type, $key, $value)
    $encoded_value = $class->($type, $key, $value)

Called during C<write_config> in order to convert values into a serializable
format.

Does nothing to C<$value> by default, but can be overridden in the I<base plugin>
in order to implement custom conversion behavior. Usually one should also
override C<decode_value> in a matching manner.

=cut

sub encode_value {
    my ($class, $type, $key, $value) = @_;

    return $value;
}

=pod

=head3 check_value

    $checked_value = PVE::Example::BasePlugin->check_value($type, $key, $value, $storeid, $skipSchemaCheck)
    $checked_value = $class->check_value($type, $key, $value, $storeid, $skipSchemaCheck)

Used internally to check if various invariants are upheld. It's best to not
override this.

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

=pod

=head3 parse_section_header

B<OPTIONAL:> Can be I<extended> in the I<base plugin>.

    ($type, $sectionId, $errmsg, $config) = PVE::Example::BasePlugin->parse_section_header($line)
    ($type, $sectionId, $errmsg, $config) = $class->parse_section_header($line)

Parses the header of a section and returns an array containing the section's
C<type>, ID and optionally an error message as well as additional config
attributes.

Can be overriden on the I<base plugin> in order to provide custom logic for
handling the header, e.g. if the section IDs need to be parsed or validated in
a certain way.

Note that the section B<MUST> initially be parsed with the regex used by the
original method when overriding in order to guarantee compatibility.
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

=pod

=head3 format_section_header

B<OPTIONAL:> Can be overridden in the I<base plugin>.

    $header = PVE::Example::BasePlugin->format_section_header($type, $sectionId, $scfg, $done_hash)
    $header = $class->format_section_header($type, $sectionId, $scfg, $done_hash)

Formats the header of a section. Simply C<"$type: $sectionId\n"> by default.

Note that when overriding this, the header B<MUST> end with a newline (C<\n>).
One also might want to add a matching override for C<parse_section_header>.

=cut

sub format_section_header {
    my ($class, $type, $sectionId, $scfg, $done_hash) = @_;

    return "$type: $sectionId\n";
}

=pod

=head3 get_property_schema

    $schema = PVE::Example::BasePlugin->get_property_schema($type, $key)
    $schema = $class->get_property_schema($type, $key)

Returns the schema of a I<property> of a I<child plugin> that is denoted via
its C<$type>.

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

=pod

=head3 parse_config

    $config = PVE::Example::BasePlugin->parse_config($filename, $raw, $allow_unknown)
    $config = $class->parse_config($filename, $raw, $allow_unknown)

Parses the contents of a C<SectionConfig> file and returns a complex nested
hash which not only contains the parsed data, but additional information that
one may or may not find useful. More below.

=over

=item C<$filename>

The name of the file whose content is stored in C<$raw>.

=item C<$raw>

The raw content of C<$filename>.

=item C<$allow_unknown>

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

Each section's parsed configuration values, or more precisely, the I<section
identifiers> and their associated configuration options as returned by
C<check_config>.

=item C<order>

The order in which the sections in C<ids> were parsed.

=item C<digest>

A SHA1 hex digest of the contents in C<$raw>.

=item C<errors> (optional)

An optional list of error hashes, where each hash contains the following keys:

=over 2

=item C<context>

In which file and in which line the error was encountered.

=item C<section>

In which section the error was encountered.

=item C<key>

Which I<property> the error corresponds to.

=item C<err>

The error.

=back

=back

=cut

sub parse_config {
    my ($class, $filename, $raw, $allow_unknown) = @_;

    if (!defined($raw)) {
	return {
	    ids => {},
	    order => {},
	    digest => Digest::SHA::sha1_hex(''),
	};
    }

    my $re_begins_with_comment = qr/^\s*#/;
    my $re_kv_pair = qr/^\s+  (\S+)  (\s+ (.*\S) )?  \s*$/x;

    my $ids = {};
    my $order = {};
    my $digest = Digest::SHA::sha1_hex($raw);

    my $current_order = 1;
    my $line_no = 0;

    my @lines = split(/\n/, $raw);
    my @errors;

    my $is_array = sub {
	my ($type, $key) = @_;

	my $schema = $class->get_property_schema($type, $key);
	die "unknown property type\n" if !$schema;

	return $schema->{type} eq 'array';
    };

    my $get_next_line = sub {
	while (scalar(@lines)) {
	    my $line = shift(@lines);
	    $line_no++;

	    next if ($line =~ m/$re_begins_with_comment/);

	    return $line;
	}

	return undef;
    };

    my $skip_to_next_empty_line = sub {
	while ($get_next_line->() ne '') {}
    };

    while (defined(my $line = $get_next_line->())) {
	next if !$line;

	my $errprefix = "file $filename line $line_no";

	my ($type, $section_id, $errmsg, $config) = $class->parse_section_header($line);

	if (!defined($config)) {
	    warn "$errprefix - ignore config line: $line\n";
	    next;
	}

	if ($errmsg) {
	    chomp $errmsg;
	    warn "$errprefix (skip section '$section_id'): $errmsg\n";
	    $skip_to_next_empty_line->();
	    next;
	}

	if (!$type) {
	    warn "$errprefix (skip section '$section_id'): missing type - internal error\n";
	    $skip_to_next_empty_line->();
	    next;
	}

	my $plugin = eval { $class->lookup($type) };
	my $is_unknown_type = defined($@) && $@ ne '';

	if ($is_unknown_type && !$allow_unknown) {
	    warn "$errprefix (skip section '$section_id'): unsupported type '$type'\n";
	    $skip_to_next_empty_line->();
	    next;
	}

	# Parse kv-pairs of section - will go on until empty line is encountered
	while (my $section_line = $get_next_line->()) {
	    if ($section_line =~ m/$re_kv_pair/) {
		my ($key, $value) = ($1, $3);

		eval {
		    if ($is_unknown_type) {
			if (!defined($config->{$key})) {
			    $config->{$key} = $value;
			} else {
			    $config->{$key} = [$config->{$key}] if !ref($config->{$key});
			    push $config->{$key}->@*, $value;
			}
		    } elsif ($is_array->($type, $key)) {
			$value = $plugin->check_value($type, $key, $value, $section_id);
			$config->{$key} = [] if !defined($config->{$key});
			push $config->{$key}->@*, $value;
		    } else {
			die "duplicate attribute\n" if defined($config->{$key});
			$value = $plugin->check_value($type, $key, $value, $section_id);
			$config->{$key} = $value;
		    }
		};
		if (my $err = $@) {
		    warn "$errprefix (section '$section_id') - unable to parse value of '$key': $err";
		    push @errors, {
			context => $errprefix,
			section => $section_id,
			key => $key,
			err => $err,
		    };
		}
	    }
	}

	if ($is_unknown_type || ($type && $plugin && $config)) {
	    $config->{type} = $type;

	    if (!$is_unknown_type) {
		$config = eval { $config = $plugin->check_config($section_id, $config, 1, 1); };
		warn "$errprefix (skip section '$section_id'): $@" if $@;
	    }

	    $ids->{$section_id} = $config;
	    $order->{$section_id} = $current_order++;
	}
    }

    my $cfg = {
	ids => $ids,
	order => $order,
	digest => $digest,
    };

    $cfg->{errors} = \@errors if scalar(@errors) > 0;

    return $cfg;
}

=pod

=head3 check_config

    $settings = PVE::Example::BasePlugin->check_config($sectionId, $config, $create, $skipSchemaCheck)
    $settings = $class->check_config($sectionId, $config, $create, $skipSchemaCheck)

Does not just check whether a section's configuration is valid, despite its
name, but also calls C<decode_value> (among other things) internally.

Returns a hash which contains all I<properties> for the given C<$sectionId>.
In other words, all configured key-value pairs for the provided section.

It's best to not override this.

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

=pod

=head3 write_config

    $output = PVE::Example::BasePlugin->write_config($filename, $cfg, $allow_unknown)
    $output = $class->write_config($filename, $cfg, $allow_unknown)

Generates the output that should be written to the C<SectionConfig> file.

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

=item C<$allow_unknown>

Whether to allow writing sections with an unknown C<type>.

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

=pod

=head3 delete_from_config

    $config = PVE::Example::BasePlugin->delete_from_config($config, $option_schema, $new_options, $to_delete)
    $config = $class->delete_from_config($config, $option_schema, $new_options, $to_delete)

Convenience method to delete key from a hash of configured I<properties> which
performs necessary checks beforehand.

Note: The passed C<$config> is modified in place and also returned.

=over

=item C<$config>

The section's configuration that the given I<properties> in C<$to_delete> should
be deleted from.

=item C<$option_schema>

The schema of the I<properties> associated with C<$config>. See the C<options>
method.

=item C<$new_options>

The I<properties> which are to be added to C<$config>. Note that this method
doesn't add any I<properties> itself; this is to prohibit simultaneously
setting and deleting the same I<property>.

=item C<$to_delete>

A reference to an array containing the names of the I<properties> to delete
from C<$config>.

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
