package PVE::SectionConfig;

use strict;
use warnings;
use Digest::SHA;
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);

use Data::Dumper;

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

sub createSchema {
    my ($class, $skip_type) = @_;

    my $pdata = $class->private();
    my $propertyList = $pdata->{propertyList};
    my $plugins = $pdata->{plugins};

    my $props = {};

    my $copy_property = sub {
	my ($src) = @_;

	my $res = {};
	foreach my $k (keys %$src) {
	    $res->{$k} = $src->{$k};
	}

	return $res;
    };

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
	    my $res = &$copy_property($propertyList->{$p});
	    $res->{optional} = 0;
	    $props->{$p} = $res;
	} else {
	    $props->{$p} = $propertyList->{$p};
	}
    }

    return {
	type => "object",
	additionalProperties => 0,
	properties => $props,
    };
}

sub updateSchema {
    my ($class, $single_class) = @_;

    my $pdata = $class->private();
    my $propertyList = $pdata->{propertyList};
    my $plugins = $pdata->{plugins};

    my $props = {};

    my $filter_type = $class->type() if $single_class;

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

sub init {
    my ($class) = @_;

    my $pdata = $class->private();

    foreach my $k (qw(options plugins plugindata propertyList)) {
	$pdata->{$k} = {} if !$pdata->{$k};
    }

    my $plugins = $pdata->{plugins};
    my $propertyList = $pdata->{propertyList};

    foreach my $type (keys %$plugins) {
	my $props = $plugins->{$type}->properties();
	foreach my $p (keys %$props) {
	    die "duplicate property '$p'" if defined($propertyList->{$p});
	    my $res = $propertyList->{$p} = {};
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
	    die "undefined property '$p'" if !$propertyList->{$p};
	}
	$pdata->{options}->{$type} = $opts;
    }

    $propertyList->{type}->{type} = 'string';
    $propertyList->{type}->{enum} = [sort keys %$plugins];
}

sub lookup {
    my ($class, $type) = @_;

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

    my $schema = $pdata->{propertyList}->{$key};
    die "unknown property type\n" if !$schema;

    my $ct = $schema->{type};

    $value = 1 if $ct eq 'boolean' && !defined($value);

    die "got undefined value\n" if !defined($value);

    die "property contains a line feed\n" if $value =~ m/[\n\r]/;

    if (!$skipSchemaCheck) {
	my $errors = {};
	PVE::JSONSchema::check_prop($value, $schema, '', $errors);
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


sub parse_config {
    my ($class, $filename, $raw) = @_;

    my $pdata = $class->private();

    my $ids = {};
    my $order = {};

    $raw = '' if !defined($raw);

    my $digest = Digest::SHA::sha1_hex($raw);
    
    my $pri = 1;

    my $lineno = 0;
    my @lines = split(/\n/, $raw);
    my $nextline = sub {
	while (my $line = shift @lines) {
	    $lineno++;
	    return $line if $line !~ /^\s*(?:#|$)/;
	}
    };

    while (my $line = &$nextline()) {
	my $errprefix = "file $filename line $lineno";

	my ($type, $sectionId, $errmsg, $config) = $class->parse_section_header($line);
	if ($config) {
	    my $ignore = 0;

	    my $plugin;

	    if ($errmsg) {
		$ignore = 1;
		chomp $errmsg;
		warn "$errprefix (skip section '$sectionId'): $errmsg\n";
	    } elsif (!$type) {
		$ignore = 1;
		warn "$errprefix (skip section '$sectionId'): missing type - internal error\n";
	    } else {
		if (!($plugin = $pdata->{plugins}->{$type})) {
		    $ignore = 1;
		    warn "$errprefix (skip section '$sectionId'): unsupported type '$type'\n";
		}
	    }

	    while ($line = &$nextline()) {
		next if $ignore; # skip

		$errprefix = "file $filename line $lineno";

		if ($line =~ m/^\s+(\S+)(\s+(.*\S))?\s*$/) {
		    my ($k, $v) = ($1, $3);
   
		    eval {
			die "duplicate attribute\n" if defined($config->{$k});
			$config->{$k} = $plugin->check_value($type, $k, $v, $sectionId);
		    };
		    warn "$errprefix (section '$sectionId') - unable to parse value of '$k': $@" if $@;

		} else {
		    warn "$errprefix (section '$sectionId') - ignore config line: $line\n";
		}
	    }

	    if (!$ignore && $type && $plugin && $config) {
		$config->{type} = $type;
		eval { $ids->{$sectionId} = $plugin->check_config($sectionId, $config, 1, 1); };
		warn "$errprefix (skip section '$sectionId'): $@" if $@;
		$order->{$sectionId} = $pri++;
	    }

	} else {
	    warn "$errprefix - ignore config line: $line\n";
	}
    }


    my $cfg = { ids => $ids, order => $order, digest => $digest};

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
	    if !$create && $opts->{$k}->{fixed};
	
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
    } else {
	return "\t$key $value\n" if "$value" ne '';
    }
};

sub write_config {
    my ($class, $filename, $cfg) = @_;

    my $pdata = $class->private();
    my $propertyList = $pdata->{propertyList};

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

	die "unknown section type '$type'\n" if !$opts;

	my $done_hash = {};

	my $data = $class->format_section_header($type, $sectionId, $scfg, $done_hash);
	if ($scfg->{comment} && !$done_hash->{comment}) {
	    my $k = 'comment';
	    my $v = $class->encode_value($type, $k, $scfg->{$k});
	    $data .= &$format_config_line($propertyList->{$k}, $k, $v);
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
	    $data .= &$format_config_line($propertyList->{$k}, $k, $v);
	}

	foreach my $k (@option_keys) {
	    next if defined($done_hash->{$k});
	    my $v = $scfg->{$k};
	    next if !defined($v);
	    $v = $class->encode_value($type, $k, $v);
	    $data .= &$format_config_line($propertyList->{$k}, $k, $v);
	}

	$out .= "$data\n";
    }

    return $out;
}

sub assert_if_modified {
    my ($cfg, $digest) = @_;

    PVE::Tools::assert_if_modified($cfg->{digest}, $digest);
}

1;
