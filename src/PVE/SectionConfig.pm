package PVE::SectionConfig;

use strict;
use warnings;

use Carp;
use Digest::SHA;

use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools;

# This package provides a way to have multiple (often similar) types of entries
# in the same config file, each in its own section, thus "Section Config".
#
# The intended structure is to have a single 'base' plugin that inherits from
# this class and provides meaningful defaults in its '$defaultData', e.g. a
# default list of the core properties in its propertyList (most often only 'id'
# and 'type')
#
# Each 'real' plugin then has it's own package that should inherit from the
# 'base' plugin and returns it's specific properties in the 'properties' method,
# its type in the 'type' method and all the known options, from both parent and
# itself, in the 'options' method.
# The options method can also be used to define if a property is 'optional' or
# 'fixed' (only settable on config entity-creation), for example:
#
# ````
# sub options {
#     return {
#         'some-optional-property' => { optional => 1 },
#         'a-fixed-property' => { fixed => 1 },
#         'a-required-but-not-fixed-property' => {},
#     };
# }
# ```
#
# 'fixed' options can be set on create, but not changed afterwards.
#
# To actually use it, you have to first register all the plugins and then init
# the 'base' plugin, like so:
#
# ```
# use PVE::Dummy::Plugin1;
# use PVE::Dummy::Plugin2;
# use PVE::Dummy::BasePlugin;
#
# PVE::Dummy::Plugin1->register();
# PVE::Dummy::Plugin2->register();
# PVE::Dummy::BasePlugin->init();
# ```
#
# There are two modes for how properties are exposed, the default 'unified'
# mode and the 'isolated' mode.
# In the default unified mode, there is only a global list of properties
# which the plugins can use, so you cannot define the same property name twice
# in different plugins. The reason for this is to force the use of identical
# properties for multiple plugins.
#
# The second way is to use the 'isolated' mode, which can be achieved by
# calling init with `1` as its parameter like this:
#
# ```
# PVE::Dummy::BasePlugin->init(property_isolation => 1);
# ```
#
# With this, each plugin get's their own isolated list of properties which it
# can use. Note that in this mode, you only have to specify the property in the
# options method when it is either 'fixed' or comes from the global list of
# properties. All locally defined ones get automatically added to the schema
# for that plugin.

my $defaultData = {
    options => {},
    plugins => {},
    plugindata => {},
    propertyList => {},
};

sub private {
    die "overwrite me";
    return $defaultData;
}

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

sub type {
    die "overwrite me";
}

sub properties {
    return {};
}

sub options {
    return {};
}

sub plugindata {
    return {};
}

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

sub createSchema {
    my ($class, $skip_type, $base) = @_;

    my $pdata = $class->private();
    my $propertyList = $pdata->{propertyList};
    my $plugins = $pdata->{plugins};

    my $props = $base || {};

    if (!$class->has_isolated_properties()) {
	foreach my $p (keys %$propertyList) {
	    next if $skip_type && $p eq 'type';

	    if (!$propertyList->{$p}->{optional}) {
		$props->{$p} = $propertyList->{$p};
		next;
	    }

	    my $required = 1;

	    my $copts = $class->options();
	    $required = 0 if defined($copts->{$p}) && $copts->{$p}->{optional};

	    foreach my $t (keys %$plugins) {
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
	for my $type (sort keys %$plugins) {
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

sub updateSchema {
    my ($class, $single_class, $base) = @_;

    my $pdata = $class->private();
    my $propertyList = $pdata->{propertyList};
    my $plugins = $pdata->{plugins};

    my $props = $base || {};

    my $filter_type = $single_class ? $class->type() : undef;

    if (!$class->has_isolated_properties()) {
	foreach my $p (keys %$propertyList) {
	    next if $p eq 'type';

	    my $copts = $class->options();

	    next if defined($filter_type) && !defined($copts->{$p});

	    if (!$propertyList->{$p}->{optional}) {
		$props->{$p} = $propertyList->{$p};
		next;
	    }

	    my $modifyable = 0;

	    $modifyable = 1 if defined($copts->{$p}) && !$copts->{$p}->{fixed};

	    foreach my $t (keys %$plugins) {
		my $opts = $pdata->{options}->{$t} || {};
		next if !defined($opts->{$p});
		$modifyable = 1 if !$opts->{$p}->{fixed};
	    }
	    next if !$modifyable;

	    $props->{$p} = $propertyList->{$p};
	}
    } else {
	for my $type (sort keys %$plugins) {
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

# the %param hash controls some behavior of the section config, currently the following options are
# understood:
#
# - property_isolation: if set, each child-plugin has a fully isolated property (schema) namespace.
#   By default this is off, meaning all child-plugins share the schema of properties with the same
#   name. Normally one wants to use oneOf schema's when enabling isolation.
sub init {
    my ($class, %param) = @_;

    my $property_isolation = $param{property_isolation};

    my $pdata = $class->private();

    foreach my $k (qw(options plugins plugindata propertyList isolatedPropertyList)) {
	$pdata->{$k} = {} if !$pdata->{$k};
    }

    my $plugins = $pdata->{plugins};
    my $propertyList = $pdata->{propertyList};
    my $isolatedPropertyList = $pdata->{isolatedPropertyList};

    foreach my $type (keys %$plugins) {
	my $props = $plugins->{$type}->properties();
	foreach my $p (keys %$props) {
	    my $res;
	    if ($property_isolation) {
		$res = $isolatedPropertyList->{$type}->{$p} = {};
	    } else {
		die "duplicate property '$p'" if defined($propertyList->{$p});
		$res = $propertyList->{$p} = {};
	    }
	    my $data = $props->{$p};
	    for my $a (keys %$data) {
		$res->{$a} = $data->{$a};
	    }
	    $res->{optional} = 1;
	}
    }

    foreach my $type (keys %$plugins) {
	my $opts = $plugins->{$type}->options();
	foreach my $p (keys %$opts) {
	    my $prop;
	    if ($property_isolation) {
		$prop = $isolatedPropertyList->{$type}->{$p};
	    }
	    $prop //= $propertyList->{$p};
	    die "undefined property '$p'" if !$prop;
	}

	# automatically the properties to options (if not specified explicitly)
	if ($property_isolation) {
	    foreach my $p (keys $isolatedPropertyList->{$type}->%*) {
		next if $opts->{$p};
		$opts->{$p} = {};
		$opts->{$p}->{optional} = 1 if $isolatedPropertyList->{$type}->{$p}->{optional};
	    }
	}

	$pdata->{options}->{$type} = $opts;
    }

    $propertyList->{type}->{type} = 'string';
    $propertyList->{type}->{enum} = [sort keys %$plugins];
}

sub lookup {
    my ($class, $type) = @_;

    croak "cannot lookup undefined type!" if !defined($type);

    my $pdata = $class->private();
    my $plugin = $pdata->{plugins}->{$type};

    die "unknown section type '$type'\n" if !$plugin;

    return $plugin;
}

sub lookup_types {
    my ($class) = @_;

    my $pdata = $class->private();

    return [ sort keys %{$pdata->{plugins}} ];
}

sub decode_value {
    my ($class, $type, $key, $value) = @_;

    return $value;
}

sub encode_value {
    my ($class, $type, $key, $value) = @_;

    return $value;
}

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
	if (scalar(keys %$errors)) {
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

sub format_section_header {
    my ($class, $type, $sectionId, $scfg, $done_hash) = @_;

    return "$type: $sectionId\n";
}

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
		next if $skip; # skip

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
			push @$errors, {
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
    $cfg->{errors} = $errors if scalar(@$errors) > 0;

    return $cfg;
}

sub check_config {
    my ($class, $sectionId, $config, $create, $skipSchemaCheck) = @_;

    my $type = $class->type();
    my $pdata = $class->private();
    my $opts = $pdata->{options}->{$type};

    my $settings = { type => $type };

    foreach my $k (keys %$config) {
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
	foreach my $k (keys %$opts) {
	    next if $opts->{$k}->{optional};
	    die "missing value for required option '$k'\n"
		if !defined($config->{$k});
	}
    }

    return $settings;
}

my $format_config_line = sub {
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

sub write_config {
    my ($class, $filename, $cfg, $allow_unknown) = @_;

    my $pdata = $class->private();

    my $out = '';

    my $ids = $cfg->{ids};
    my $order = $cfg->{order};

    my $maxpri = 0;
    foreach my $sectionId (keys %$ids) {
	my $pri = $order->{$sectionId};
	$maxpri = $pri if $pri && $pri > $maxpri;
    }
    foreach my $sectionId (keys %$ids) {
	if (!defined ($order->{$sectionId})) {
	    $order->{$sectionId} = ++$maxpri;
	}
    }

    foreach my $sectionId (sort {$order->{$a} <=> $order->{$b}} keys %$ids) {
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
	    for my $k (@first, sort keys %$scfg) {
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
	    $data .= &$format_config_line($prop, $k, $v);
	}

	$data .= "\tdisable\n" if $scfg->{disable} && !$done_hash->{disable};

	$done_hash->{comment} = 1;
	$done_hash->{disable} = 1;

	my @option_keys = sort keys %$opts;
	foreach my $k (@option_keys) {
	    next if defined($done_hash->{$k});
	    next if $opts->{$k}->{optional};
	    $done_hash->{$k} = 1;
	    my $v = $scfg->{$k};
	    die "section '$sectionId' - missing value for required option '$k'\n"
		if !defined ($v);
	    $v = $class->encode_value($type, $k, $v);
	    my $prop = $class->get_property_schema($type, $k);
	    $data .= &$format_config_line($prop, $k, $v);
	}

	foreach my $k (@option_keys) {
	    next if defined($done_hash->{$k});
	    my $v = $scfg->{$k};
	    next if !defined($v);
	    $v = $class->encode_value($type, $k, $v);
	    my $prop = $class->get_property_schema($type, $k);
	    $data .= &$format_config_line($prop, $k, $v);
	}

	$out .= "$data\n";
    }

    return $out;
}

sub assert_if_modified {
    my ($cfg, $digest) = @_;

    PVE::Tools::assert_if_modified($cfg->{digest}, $digest);
}

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
