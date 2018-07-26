package PVE::JSONSchema;

use strict;
use warnings;
use Storable; # for dclone
use Getopt::Long;
use Encode::Locale;
use Encode;
use Devel::Cycle -quiet; # todo: remove?
use PVE::Tools qw(split_list $IPV6RE $IPV4RE);
use PVE::Exception qw(raise);
use HTTP::Status qw(:constants);
use Net::IP qw(:PROC);
use Data::Dumper;

use base 'Exporter';

our @EXPORT_OK = qw(
register_standard_option 
get_standard_option
);

# Note: This class implements something similar to JSON schema, but it is not 100% complete. 
# see: http://tools.ietf.org/html/draft-zyp-json-schema-02
# see: http://json-schema.org/

# the code is similar to the javascript parser from http://code.google.com/p/jsonschema/

my $standard_options = {};
sub register_standard_option {
    my ($name, $schema) = @_;

    die "standard option '$name' already registered\n" 
	if $standard_options->{$name};

    $standard_options->{$name} = $schema;
}

sub get_standard_option {
    my ($name, $base) = @_;

    my $std =  $standard_options->{$name};
    die "no such standard option '$name'\n" if !$std;

    my $res = $base || {};

    foreach my $opt (keys %$std) {
	next if defined($res->{$opt});
	$res->{$opt} = $std->{$opt};
    }

    return $res;
};

register_standard_option('pve-vmid', {
    description => "The (unique) ID of the VM.",
    type => 'integer', format => 'pve-vmid',
    minimum => 1
});

register_standard_option('pve-node', {
    description => "The cluster node name.",
    type => 'string', format => 'pve-node',
});

register_standard_option('pve-node-list', {
    description => "List of cluster node names.",
    type => 'string', format => 'pve-node-list',
});

register_standard_option('pve-iface', {
    description => "Network interface name.",
    type => 'string', format => 'pve-iface',
    minLength => 2, maxLength => 20,
});

register_standard_option('pve-storage-id', {
    description => "The storage identifier.",
    type => 'string', format => 'pve-storage-id',
}); 

register_standard_option('pve-config-digest', {
    description => 'Prevent changes if current configuration file has different SHA1 digest. This can be used to prevent concurrent modifications.',
    type => 'string',
    optional => 1,
    maxLength => 40, # sha1 hex digest lenght is 40
});

register_standard_option('skiplock', {
    description => "Ignore locks - only root is allowed to use this option.",
    type => 'boolean',
    optional => 1,
});

register_standard_option('extra-args', {
    description => "Extra arguments as array",
    type => 'array',
    items => { type => 'string' },
    optional => 1
});

register_standard_option('fingerprint-sha256', {
    description => "Certificate SHA 256 fingerprint.",
    type => 'string',
    pattern => '([A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2}',
});

register_standard_option('pve-output-format', {
    type => 'string',
    description => 'Output format.',
    enum => [ 'text', 'json', 'json-pretty', 'yaml' ],
    optional => 1,
    default => 'text',
});

my $format_list = {};

sub register_format {
    my ($format, $code) = @_;

    die "JSON schema format '$format' already registered\n" 
	if $format_list->{$format};

    $format_list->{$format} = $code;
}

sub get_format {
    my ($format) = @_;
    return $format_list->{$format};
}

my $renderer_hash = {};

sub register_renderer {
    my ($name, $code) = @_;

    die "renderer '$name' already registered\n"
	if $renderer_hash->{$name};

    $renderer_hash->{$name} = $code;
}

sub get_renderer {
    my ($name) = @_;
    return $renderer_hash->{$name};
}

# register some common type for pve

register_format('string', sub {}); # allow format => 'string-list'

register_format('urlencoded', \&pve_verify_urlencoded);
sub pve_verify_urlencoded {
    my ($text, $noerr) = @_;
    if ($text !~ /^[-%a-zA-Z0-9_.!~*'()]*$/) {
	return undef if $noerr;
	die "invalid urlencoded string: $text\n";
    }
    return $text;
}

register_format('pve-configid', \&pve_verify_configid);
sub pve_verify_configid {
    my ($id, $noerr) = @_;
 
    if ($id !~ m/^[a-z][a-z0-9_]+$/i) {
	return undef if $noerr;
	die "invalid configuration ID '$id'\n"; 
    }
    return $id;
}

PVE::JSONSchema::register_format('pve-storage-id', \&parse_storage_id);
sub parse_storage_id {
    my ($storeid, $noerr) = @_;

    if ($storeid !~ m/^[a-z][a-z0-9\-\_\.]*[a-z0-9]$/i) {
	return undef if $noerr;
	die "storage ID '$storeid' contains illegal characters\n";
    }
    return $storeid;
}


register_format('pve-vmid', \&pve_verify_vmid);
sub pve_verify_vmid {
    my ($vmid, $noerr) = @_;

    if ($vmid !~ m/^[1-9][0-9]{2,8}$/) {
	return undef if $noerr;
	die "value does not look like a valid VM ID\n";
    }
    return $vmid;
}

register_format('pve-node', \&pve_verify_node_name);
sub pve_verify_node_name {
    my ($node, $noerr) = @_;

    if ($node !~ m/^([a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)$/) {
	return undef if $noerr;
	die "value does not look like a valid node name\n";
    }
    return $node;
}

register_format('ipv4', \&pve_verify_ipv4);
sub pve_verify_ipv4 {
    my ($ipv4, $noerr) = @_;

    if ($ipv4 !~ m/^(?:$IPV4RE)$/) {
 	return undef if $noerr;
	die "value does not look like a valid IPv4 address\n";
    }
    return $ipv4;
}

register_format('ipv6', \&pve_verify_ipv6);
sub pve_verify_ipv6 {
    my ($ipv6, $noerr) = @_;

    if ($ipv6 !~ m/^(?:$IPV6RE)$/) {
 	return undef if $noerr;
	die "value does not look like a valid IPv6 address\n";
    }
    return $ipv6;
}

register_format('ip', \&pve_verify_ip);
sub pve_verify_ip {
    my ($ip, $noerr) = @_;

    if ($ip !~ m/^(?:(?:$IPV4RE)|(?:$IPV6RE))$/) {
 	return undef if $noerr;
	die "value does not look like a valid IP address\n";
    }
    return $ip;
}

my $ipv4_mask_hash = {
    '128.0.0.0' => 1,
    '192.0.0.0' => 2,
    '224.0.0.0' => 3,
    '240.0.0.0' => 4,
    '248.0.0.0' => 5,
    '252.0.0.0' => 6,
    '254.0.0.0' => 7,
    '255.0.0.0' => 8,
    '255.128.0.0' => 9,
    '255.192.0.0' => 10,
    '255.224.0.0' => 11,
    '255.240.0.0' => 12,
    '255.248.0.0' => 13,
    '255.252.0.0' => 14,
    '255.254.0.0' => 15,
    '255.255.0.0' => 16,
    '255.255.128.0' => 17,
    '255.255.192.0' => 18,
    '255.255.224.0' => 19,
    '255.255.240.0' => 20,
    '255.255.248.0' => 21,
    '255.255.252.0' => 22,
    '255.255.254.0' => 23,
    '255.255.255.0' => 24,
    '255.255.255.128' => 25,
    '255.255.255.192' => 26,
    '255.255.255.224' => 27,
    '255.255.255.240' => 28,
    '255.255.255.248' => 29,
    '255.255.255.252' => 30,
    '255.255.255.254' => 31,
    '255.255.255.255' => 32,
};

register_format('ipv4mask', \&pve_verify_ipv4mask);
sub pve_verify_ipv4mask {
    my ($mask, $noerr) = @_;

    if (!defined($ipv4_mask_hash->{$mask})) {
	return undef if $noerr;
	die "value does not look like a valid IP netmask\n";
    }
    return $mask;
}

register_format('CIDRv6', \&pve_verify_cidrv6);
sub pve_verify_cidrv6 {
    my ($cidr, $noerr) = @_;

    if ($cidr =~ m!^(?:$IPV6RE)(?:/(\d+))$! && ($1 > 7) && ($1 <= 128)) {
	return $cidr;
    }

    return undef if $noerr;
    die "value does not look like a valid IPv6 CIDR network\n";
}

register_format('CIDRv4', \&pve_verify_cidrv4);
sub pve_verify_cidrv4 {
    my ($cidr, $noerr) = @_;

    if ($cidr =~ m!^(?:$IPV4RE)(?:/(\d+))$! && ($1 > 7) &&  ($1 <= 32)) {
	return $cidr;
    }

    return undef if $noerr;
    die "value does not look like a valid IPv4 CIDR network\n";
}

register_format('CIDR', \&pve_verify_cidr);
sub pve_verify_cidr {
    my ($cidr, $noerr) = @_;

    if (!(pve_verify_cidrv4($cidr, 1) ||
	  pve_verify_cidrv6($cidr, 1)))
    {
	return undef if $noerr;
	die "value does not look like a valid CIDR network\n";
    }

    return $cidr;
}

register_format('pve-ipv4-config', \&pve_verify_ipv4_config);
sub pve_verify_ipv4_config {
    my ($config, $noerr) = @_;

    return $config if $config =~ /^(?:dhcp|manual)$/ ||
                      pve_verify_cidrv4($config, 1);
    return undef if $noerr;
    die "value does not look like a valid ipv4 network configuration\n";
}

register_format('pve-ipv6-config', \&pve_verify_ipv6_config);
sub pve_verify_ipv6_config {
    my ($config, $noerr) = @_;

    return $config if $config =~ /^(?:auto|dhcp|manual)$/ ||
                      pve_verify_cidrv6($config, 1);
    return undef if $noerr;
    die "value does not look like a valid ipv6 network configuration\n";
}

register_format('email', \&pve_verify_email);
sub pve_verify_email {
    my ($email, $noerr) = @_;

    # we use same regex as in Utils.js
    if ($email !~ /^(\w+)([\-+.][\w]+)*@(\w[\-\w]*\.){1,5}([A-Za-z]){2,63}$/) {
	   return undef if $noerr;
	   die "value does not look like a valid email address\n";
    }
    return $email;
}

register_format('dns-name', \&pve_verify_dns_name);
sub pve_verify_dns_name {
    my ($name, $noerr) = @_;

    my $namere = "([a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)";

    if ($name !~ /^(${namere}\.)*${namere}$/) {
	   return undef if $noerr;
	   die "value does not look like a valid DNS name\n";
    }
    return $name;
}

# network interface name
register_format('pve-iface', \&pve_verify_iface);
sub pve_verify_iface {
    my ($id, $noerr) = @_;
 
    if ($id !~ m/^[a-z][a-z0-9_]{1,20}([:\.]\d+)?$/i) {
	return undef if $noerr;
	die "invalid network interface name '$id'\n"; 
    }
    return $id;
}

# general addresses by name or IP
register_format('address', \&pve_verify_address);
sub pve_verify_address {
    my ($addr, $noerr) = @_;

    if (!(pve_verify_ip($addr, 1) ||
	  pve_verify_dns_name($addr, 1)))
    {
	   return undef if $noerr;
	   die "value does not look like a valid address: $addr\n";
    }
    return $addr;
}

register_format('disk-size', \&pve_verify_disk_size);
sub pve_verify_disk_size {
    my ($size, $noerr) = @_;
    if (!defined(parse_size($size))) {
	return undef if $noerr;
	die "value does not look like a valid disk size: $size\n";
    }
    return $size;
}

register_standard_option('spice-proxy', {
    description => "SPICE proxy server. This can be used by the client to specify the proxy server. All nodes in a cluster runs 'spiceproxy', so it is up to the client to choose one. By default, we return the node where the VM is currently running. As resonable setting is to use same node you use to connect to the API (This is window.location.hostname for the JS GUI).",
    type => 'string', format => 'address',
}); 

register_standard_option('remote-viewer-config', {
    description => "Returned values can be directly passed to the 'remote-viewer' application.",
    additionalProperties => 1,
    properties => {
	type => { type => 'string' },
	password => { type => 'string' },
	proxy => { type => 'string' },
	host => { type => 'string' },
	'tls-port' => { type => 'integer' },
    },
});

register_format('pve-startup-order', \&pve_verify_startup_order);
sub pve_verify_startup_order {
    my ($value, $noerr) = @_;

    return $value if pve_parse_startup_order($value);

    return undef if $noerr;

    die "unable to parse startup options\n";
}

my %bwlimit_opt = (
    optional => 1,
    type => 'number', minimum => '0',
    format_description => 'LIMIT',
);

my $bwlimit_format = {
	default => {
	    %bwlimit_opt,
	    description => 'default bandwidth limit in MiB/s',
	},
	restore => {
	    %bwlimit_opt,
	    description => 'bandwidth limit in MiB/s for restoring guests from backups',
	},
	migration => {
	    %bwlimit_opt,
	    description => 'bandwidth limit in MiB/s for migrating guests',
	},
	clone => {
	    %bwlimit_opt,
	    description => 'bandwidth limit in MiB/s for cloning disks',
	},
	move => {
	    %bwlimit_opt,
	    description => 'bandwidth limit in MiB/s for moving disks',
	},
};
register_format('bwlimit', $bwlimit_format);
register_standard_option('bwlimit', {
    description => "Set bandwidth/io limits various operations.",
    optional => 1,
    type => 'string',
    format => $bwlimit_format,
});

sub pve_parse_startup_order {
    my ($value) = @_;

    return undef if !$value;

    my $res = {};

    foreach my $p (split(/,/, $value)) {
	next if $p =~ m/^\s*$/;

	if ($p =~ m/^(order=)?(\d+)$/) {
	    $res->{order} = $2;
	} elsif ($p =~ m/^up=(\d+)$/) {
	    $res->{up} = $1;
	} elsif ($p =~ m/^down=(\d+)$/) {
	    $res->{down} = $1;
	} else {
	    return undef;
	}
    }

    return $res;
}

PVE::JSONSchema::register_standard_option('pve-startup-order', {
    description => "Startup and shutdown behavior. Order is a non-negative number defining the general startup order. Shutdown in done with reverse ordering. Additionally you can set the 'up' or 'down' delay in seconds, which specifies a delay to wait before the next VM is started or stopped.",
    optional => 1,
    type => 'string', format => 'pve-startup-order',
    typetext => '[[order=]\d+] [,up=\d+] [,down=\d+] ',
});

sub check_format {
    my ($format, $value, $path) = @_;

    return parse_property_string($format, $value, $path) if ref($format) eq 'HASH';
    return if $format eq 'regex';

    if ($format =~ m/^(.*)-a?list$/) {
	
	my $code = $format_list->{$1};

	die "undefined format '$format'\n" if !$code;

	# Note: we allow empty lists
	foreach my $v (split_list($value)) {
	    &$code($v);
	}

    } elsif ($format =~ m/^(.*)-opt$/) {

	my $code = $format_list->{$1};

	die "undefined format '$format'\n" if !$code;

	return if !$value; # allow empty string

 	&$code($value);

   } else {

	my $code = $format_list->{$format};

	die "undefined format '$format'\n" if !$code;

	return parse_property_string($code, $value, $path) if ref($code) eq 'HASH';
	&$code($value);
    }
} 

sub parse_size {
    my ($value) = @_;

    return undef if $value !~ m/^(\d+(\.\d+)?)([KMGT])?$/;
    my ($size, $unit) = ($1, $3);
    if ($unit) {
	if ($unit eq 'K') {
	    $size = $size * 1024;
	} elsif ($unit eq 'M') {
	    $size = $size * 1024 * 1024;
	} elsif ($unit eq 'G') {
	    $size = $size * 1024 * 1024 * 1024;
	} elsif ($unit eq 'T') {
	    $size = $size * 1024 * 1024 * 1024 * 1024;
	}
    }
    return int($size);
};

sub format_size {
    my ($size) = @_;

    $size = int($size);

    my $kb = int($size/1024);
    return $size if $kb*1024 != $size;

    my $mb = int($kb/1024);
    return "${kb}K" if $mb*1024 != $kb;

    my $gb = int($mb/1024);
    return "${mb}M" if $gb*1024 != $mb;

    my $tb = int($gb/1024);
    return "${gb}G" if $tb*1024 != $gb;

    return "${tb}T";
};

sub parse_boolean {
    my ($bool) = @_;
    return 1 if $bool =~ m/^(1|on|yes|true)$/i;
    return 0 if $bool =~ m/^(0|off|no|false)$/i;
    return undef;
}

sub parse_property_string {
    my ($format, $data, $path, $additional_properties) = @_;

    # In property strings we default to not allowing additional properties
    $additional_properties = 0 if !defined($additional_properties);

    # Support named formats here, too:
    if (!ref($format)) {
	if (my $desc = $format_list->{$format}) {
	    $format = $desc;
	} else {
	    die "unknown format: $format\n";
	}
    } elsif (ref($format) ne 'HASH') {
	die "unexpected format value of type ".ref($format)."\n";
    }

    my $default_key;

    my $res = {};
    foreach my $part (split(/,/, $data)) {
	next if $part =~ /^\s*$/;

	if ($part =~ /^([^=]+)=(.+)$/) {
	    my ($k, $v) = ($1, $2);
	    die "duplicate key in comma-separated list property: $k\n" if defined($res->{$k});
	    my $schema = $format->{$k};
	    if (my $alias = $schema->{alias}) {
		if (my $key_alias = $schema->{keyAlias}) {
		    die "key alias '$key_alias' is already defined\n" if defined($res->{$key_alias});
		    $res->{$key_alias} = $k;
		}
		$k = $alias;
		$schema = $format->{$k};
	    }

	    die "invalid key in comma-separated list property: $k\n" if !$schema;
	    if ($schema->{type} && $schema->{type} eq 'boolean') {
		$v = parse_boolean($v) // $v;
	    }
	    $res->{$k} = $v;
	} elsif ($part !~ /=/) {
	    die "duplicate key in comma-separated list property: $default_key\n" if $default_key;
	    foreach my $key (keys %$format) {
		if ($format->{$key}->{default_key}) {
		    $default_key = $key;
		    if (!$res->{$default_key}) {
			$res->{$default_key} = $part;
			last;
		    }
		    die "duplicate key in comma-separated list property: $default_key\n";
		}
	    }
	    die "value without key, but schema does not define a default key\n" if !$default_key;
	} else {
	    die "missing key in comma-separated list property\n";
	}
    }

    my $errors = {};
    check_object($path, $format, $res, $additional_properties, $errors);
    if (scalar(%$errors)) {
	raise "format error\n", errors => $errors;
    }

    return $res;
}

sub add_error {
    my ($errors, $path, $msg) = @_;

    $path = '_root' if !$path;
    
    if ($errors->{$path}) {
	$errors->{$path} = join ('\n', $errors->{$path}, $msg);
    } else {
	$errors->{$path} = $msg;
    }
}

sub is_number {
    my $value = shift;

    # see 'man perlretut'
    return $value =~ /^[+-]?(\d+\.\d+|\d+\.|\.\d+|\d+)([eE][+-]?\d+)?$/; 
}

sub is_integer {
    my $value = shift;

    return $value =~ m/^[+-]?\d+$/;
}

sub check_type {
    my ($path, $type, $value, $errors) = @_;

    return 1 if !$type;

    if (!defined($value)) {
	return 1 if $type eq 'null';
	die "internal error" 
    }

    if (my $tt = ref($type)) {
	if ($tt eq 'ARRAY') {
	    foreach my $t (@$type) {
		my $tmperr = {};
		check_type($path, $t, $value, $tmperr);
		return 1 if !scalar(%$tmperr); 
	    }
	    my $ttext = join ('|', @$type);
	    add_error($errors, $path, "type check ('$ttext') failed"); 
	    return undef;
	} elsif ($tt eq 'HASH') {
	    my $tmperr = {};
	    check_prop($value, $type, $path, $tmperr);
	    return 1 if !scalar(%$tmperr); 
	    add_error($errors, $path, "type check failed"); 	    
	    return undef;
	} else {
	    die "internal error - got reference type '$tt'";
	}

    } else {

	return 1 if $type eq 'any';

	if ($type eq 'null') {
	    if (defined($value)) {
		add_error($errors, $path, "type check ('$type') failed - value is not null");
		return undef;
	    }
	    return 1;
	}

	my $vt = ref($value);

	if ($type eq 'array') {
	    if (!$vt || $vt ne 'ARRAY') {
		add_error($errors, $path, "type check ('$type') failed");
		return undef;
	    }
	    return 1;
	} elsif ($type eq 'object') {
	    if (!$vt || $vt ne 'HASH') {
		add_error($errors, $path, "type check ('$type') failed");
		return undef;
	    }
	    return 1;
	} elsif ($type eq 'coderef') {
	    if (!$vt || $vt ne 'CODE') {
		add_error($errors, $path, "type check ('$type') failed");
		return undef;
	    }
	    return 1;
	} elsif ($type eq 'string' && $vt eq 'Regexp') {
	    # qr// regexes can be used as strings and make sense for format=regex
	    return 1;
	} else {
	    if ($vt) {
		add_error($errors, $path, "type check ('$type') failed - got $vt");
		return undef;
	    } else {
		if ($type eq 'string') {
		    return 1; # nothing to check ?
		} elsif ($type eq 'boolean') {
		    #if ($value =~ m/^(1|true|yes|on)$/i) {
		    if ($value eq '1') {
			return 1;
		    #} elsif ($value =~ m/^(0|false|no|off)$/i) {
		    } elsif ($value eq '0') {
			return 1; # return success (not value)
		    } else {
			add_error($errors, $path, "type check ('$type') failed - got '$value'");
			return undef;
		    }
		} elsif ($type eq 'integer') {
		    if (!is_integer($value)) {
			add_error($errors, $path, "type check ('$type') failed - got '$value'");
			return undef;
		    }
		    return 1;
		} elsif ($type eq 'number') {
		    if (!is_number($value)) {
			add_error($errors, $path, "type check ('$type') failed - got '$value'");
			return undef;
		    }
		    return 1;
		} else {
		    return 1; # no need to verify unknown types
		}
	    }
	}
    }  

    return undef;
}

sub check_object {
    my ($path, $schema, $value, $additional_properties, $errors) = @_;

    # print "Check Object " . Dumper($value) . "\nSchema: " . Dumper($schema);

    my $st = ref($schema);
    if (!$st || $st ne 'HASH') {
	add_error($errors, $path, "Invalid schema definition.");
	return;
    }

    my $vt = ref($value);
    if (!$vt || $vt ne 'HASH') {
	add_error($errors, $path, "an object is required");
	return;
    }

    foreach my $k (keys %$schema) {
	check_prop($value->{$k}, $schema->{$k}, $path ? "$path.$k" : $k, $errors);
    }

    foreach my $k (keys %$value) {

	my $newpath =  $path ? "$path.$k" : $k;

	if (my $subschema = $schema->{$k}) {
	    if (my $requires = $subschema->{requires}) {
		if (ref($requires)) {
		    #print "TEST: " . Dumper($value) . "\n", Dumper($requires) ;
		    check_prop($value, $requires, $path, $errors);
		} elsif (!defined($value->{$requires})) {
		    add_error($errors, $path ? "$path.$requires" : $requires, 
			      "missing property - '$newpath' requires this property");
		}
	    }

	    next; # value is already checked above
	}

	if (defined ($additional_properties) && !$additional_properties) {
	    add_error($errors, $newpath, "property is not defined in schema " .
		      "and the schema does not allow additional properties");
	    next;
	}
	check_prop($value->{$k}, $additional_properties, $newpath, $errors)
	    if ref($additional_properties);
    }
}

sub check_object_warn {
    my ($path, $schema, $value, $additional_properties) = @_;
    my $errors = {};
    check_object($path, $schema, $value, $additional_properties, $errors);
    if (scalar(%$errors)) {
	foreach my $k (keys %$errors) {
	    warn "parse error: $k: $errors->{$k}\n";
	}
	return 0;
    }
    return 1;
}

sub check_prop {
    my ($value, $schema, $path, $errors) = @_;

    die "internal error - no schema" if !$schema;
    die "internal error" if !$errors;

    #print "check_prop $path\n" if $value;

    my $st = ref($schema);
    if (!$st || $st ne 'HASH') {
	add_error($errors, $path, "Invalid schema definition.");
	return;
    }

    # if it extends another schema, it must pass that schema as well
    if($schema->{extends}) {
	check_prop($value, $schema->{extends}, $path, $errors);
    }

    if (!defined ($value)) {
	return if $schema->{type} && $schema->{type} eq 'null';
	if (!$schema->{optional} && !$schema->{alias} && !$schema->{group}) {
	    add_error($errors, $path, "property is missing and it is not optional");
	}
	return;
    }

    return if !check_type($path, $schema->{type}, $value, $errors);

    if ($schema->{disallow}) {
	my $tmperr = {};
	if (check_type($path, $schema->{disallow}, $value, $tmperr)) {
	    add_error($errors, $path, "disallowed value was matched");
	    return;
	}
    }

    if (my $vt = ref($value)) {

	if ($vt eq 'ARRAY') {
	    if ($schema->{items}) {
		my $it = ref($schema->{items});
		if ($it && $it eq 'ARRAY') {
		    #die "implement me $path: $vt " . Dumper($schema) ."\n".  Dumper($value);
		    die "not implemented";
		} else {
		    my $ind = 0;
		    foreach my $el (@$value) {
			check_prop($el, $schema->{items}, "${path}[$ind]", $errors);
			$ind++;
		    }
		}
	    }
	    return; 
	} elsif ($schema->{properties} || $schema->{additionalProperties}) {
	    check_object($path, defined($schema->{properties}) ? $schema->{properties} : {},
			 $value, $schema->{additionalProperties}, $errors);
	    return;
	}

    } else {

	if (my $format = $schema->{format}) {
	    eval { check_format($format, $value, $path); };
	    if ($@) {
		add_error($errors, $path, "invalid format - $@");
		return;
	    }
	}

	if (my $pattern = $schema->{pattern}) {
	    if ($value !~ m/^$pattern$/) {
		add_error($errors, $path, "value does not match the regex pattern");
		return;
	    }
	}

	if (defined (my $max = $schema->{maxLength})) {
	    if (length($value) > $max) {
		add_error($errors, $path, "value may only be $max characters long");
		return;
	    }
	}

	if (defined (my $min = $schema->{minLength})) {
	    if (length($value) < $min) {
		add_error($errors, $path, "value must be at least $min characters long");
		return;
	    }
	}
	
	if (is_number($value)) {
	    if (defined (my $max = $schema->{maximum})) {
		if ($value > $max) { 
		    add_error($errors, $path, "value must have a maximum value of $max");
		    return;
		}
	    }

	    if (defined (my $min = $schema->{minimum})) {
		if ($value < $min) { 
		    add_error($errors, $path, "value must have a minimum value of $min");
		    return;
		}
	    }
	}

	if (my $ea = $schema->{enum}) {

	    my $found;
	    foreach my $ev (@$ea) {
		if ($ev eq $value) {
		    $found = 1;
		    last;
		}
	    }
	    if (!$found) {
		add_error($errors, $path, "value '$value' does not have a value in the enumeration '" .
			  join(", ", @$ea) . "'");
	    }
	}
    }
}

sub validate {
    my ($instance, $schema, $errmsg) = @_;

    my $errors = {};
    $errmsg = "Parameter verification failed.\n" if !$errmsg;

    # todo: cycle detection is only needed for debugging, I guess
    # we can disable that in the final release
    # todo: is there a better/faster way to detect cycles?
    my $cycles = 0;
    find_cycle($instance, sub { $cycles = 1 });
    if ($cycles) {
	add_error($errors, undef, "data structure contains recursive cycles");
    } elsif ($schema) {
	check_prop($instance, $schema, '', $errors);
    }
    
    if (scalar(%$errors)) {
	raise $errmsg, code => HTTP_BAD_REQUEST, errors => $errors;
    }

    return 1;
}

my $schema_valid_types = ["string", "object", "coderef", "array", "boolean", "number", "integer", "null", "any"];
my $default_schema_noref = {
    description => "This is the JSON Schema for JSON Schemas.",
    type => [ "object" ],
    additionalProperties => 0,
    properties => {
	type => {
	    type => ["string", "array"],
	    description => "This is a type definition value. This can be a simple type, or a union type",
	    optional => 1,
	    default => "any",
	    items => {
		type => "string",
		enum => $schema_valid_types,
	    },
	    enum => $schema_valid_types,
	},
	optional => {
	    type => "boolean",
	    description => "This indicates that the instance property in the instance object is not required.",
	    optional => 1,
	    default => 0
	},
	properties => {
	    type => "object",
	    description => "This is a definition for the properties of an object value",
	    optional => 1,
	    default => {},
	},
	items => {
	    type => "object",
	    description => "When the value is an array, this indicates the schema to use to validate each item in an array",
	    optional => 1,
	    default => {},
	},
	additionalProperties => {
	    type => [ "boolean", "object"],
	    description => "This provides a default property definition for all properties that are not explicitly defined in an object type definition.",
	    optional => 1,
	    default => {},
	},
	minimum => {
	    type => "number",
	    optional => 1,
	    description => "This indicates the minimum value for the instance property when the type of the instance value is a number.",
	},
	maximum => {
	    type => "number",
	    optional => 1,
	    description => "This indicates the maximum value for the instance property when the type of the instance value is a number.",
	},
	minLength => {
	    type => "integer",
	    description => "When the instance value is a string, this indicates minimum length of the string",
	    optional => 1,
	    minimum => 0,
	    default => 0,
	},	
	maxLength => {
	    type => "integer",
	    description => "When the instance value is a string, this indicates maximum length of the string.",
	    optional => 1,
	},
	typetext => {
	    type => "string",
	    optional => 1,
	    description => "A text representation of the type (used to generate documentation).",
	},
	pattern => {
	    type => "string",
	    format => "regex",
	    description => "When the instance value is a string, this provides a regular expression that a instance string value should match in order to be valid.",
	    optional => 1,
	    default => ".*",
	},
	enum => {
	    type => "array",
	    optional => 1,
	    description => "This provides an enumeration of possible values that are valid for the instance property.",
	},
	description => {
	    type => "string",
	    optional => 1,
	    description => "This provides a description of the purpose the instance property. The value can be a string or it can be an object with properties corresponding to various different instance languages (with an optional default property indicating the default description).",
	},
	verbose_description => {
	    type => "string",
	    optional => 1,
	    description => "This provides a more verbose description.",
	},
	format_description => {
	    type => "string",
	    optional => 1,
	    description => "This provides a shorter (usually just one word) description for a property used to generate descriptions for comma separated list property strings.",
	},
	title => {
	    type => "string",
	    optional => 1,
	    description => "This provides the title of the property",
	},
	renderer => {
	    type => "string",
	    optional => 1,
	    description => "This is used to provide rendering hints to format cli command output.",
	},
	requires => {
	    type => [ "string", "object" ],
	    optional => 1,
	    description => "indicates a required property or a schema that must be validated if this property is present",
	},
	format => {
	    type => [ "string", "object" ],
	    optional => 1,
	    description => "This indicates what format the data is among some predefined formats which may include:\n\ndate - a string following the ISO format \naddress \nschema - a schema definition object \nperson \npage \nhtml - a string representing HTML",
	},
	default_key => {
	    type => "boolean",
	    optional => 1,
	    description => "Whether this is the default key in a comma separated list property string.",
	},
	alias => {
	    type => 'string',
	    optional => 1,
	    description => "When a key represents the same property as another it can be an alias to it, causing the parsed datastructure to use the other key to store the current value under.",
	},
	keyAlias => {
	    type => 'string',
	    optional => 1,
	    description => "Allows to store the current 'key' as value of another property. Only valid if used together with 'alias'.",
	    requires => 'alias',
	},
	default => {
	    type => "any",
	    optional => 1,
	    description => "This indicates the default for the instance property."
	},
	completion => {
	    type => 'coderef',
	    description => "Bash completion function. This function should return a list of possible values.",
	    optional => 1,
	},
	disallow => {
	    type => "object",
	    optional => 1,
	    description => "This attribute may take the same values as the \"type\" attribute, however if the instance matches the type or if this value is an array and the instance matches any type or schema in the array, then this instance is not valid.",
	},
	extends => {
	    type => "object",
	    optional => 1,
	    description => "This indicates the schema extends the given schema. All instances of this schema must be valid to by the extended schema also.",
	    default => {},
	},
	# this is from hyper schema
	links => {
	    type => "array",
	    description => "This defines the link relations of the instance objects",
	    optional => 1,
	    items => {
		type => "object",
		properties => {
		    href => {
			type => "string",
			description => "This defines the target URL for the relation and can be parameterized using {propertyName} notation. It should be resolved as a URI-reference relative to the URI that was used to retrieve the instance document",
		    },
		    rel => {
			type => "string",
			description => "This is the name of the link relation",
			optional => 1,
			default => "full",
		    },
		    method => {
			type => "string",
			description => "For submission links, this defines the method that should be used to access the target resource",
			optional => 1,
			default => "GET",
		    },
		},
	    },
	},
	print_width => {
	    type => "integer",
	    description => "For CLI context, this defines the maximal width to print before truncating",
	    optional => 1,
	},
    }	
};

my $default_schema = Storable::dclone($default_schema_noref);

$default_schema->{properties}->{properties}->{additionalProperties} = $default_schema;
$default_schema->{properties}->{additionalProperties}->{properties} = $default_schema->{properties};

$default_schema->{properties}->{items}->{properties} = $default_schema->{properties};
$default_schema->{properties}->{items}->{additionalProperties} = 0;

$default_schema->{properties}->{disallow}->{properties} = $default_schema->{properties};
$default_schema->{properties}->{disallow}->{additionalProperties} = 0;

$default_schema->{properties}->{requires}->{properties} = $default_schema->{properties};
$default_schema->{properties}->{requires}->{additionalProperties} = 0;

$default_schema->{properties}->{extends}->{properties} = $default_schema->{properties};
$default_schema->{properties}->{extends}->{additionalProperties} = 0;

my $method_schema = {
    type => "object",
    additionalProperties => 0,
    properties => {
	description => {
	    description => "This a description of the method",
	    optional => 1,
	},
	name => {
	    type =>  'string',
	    description => "This indicates the name of the function to call.",
	    optional => 1,
            requires => {
 		additionalProperties => 1,
		properties => {
                    name => {},
                    description => {},
                    code => {},
 	            method => {},
                    parameters => {},
                    path => {},
                    parameters => {},
                    returns => {},
                }             
            },
	},
	method => {
	    type =>  'string',
	    description => "The HTTP method name.",
	    enum => [ 'GET', 'POST', 'PUT', 'DELETE' ],
	    optional => 1,
	},
        protected => {
            type => 'boolean',
	    description => "Method needs special privileges - only pvedaemon can execute it",            
	    optional => 1,
        },
        download => {
            type => 'boolean',
	    description => "Method downloads the file content (filename is the return value of the method).",
	    optional => 1,
        },
	proxyto => {
	    type =>  'string',
	    description => "A parameter name. If specified, all calls to this method are proxied to the host contained in that parameter.",
	    optional => 1,
	},
	proxyto_callback => {
	    type =>  'coderef',
	    description => "A function which is called to resolve the proxyto attribute. The default implementaion returns the value of the 'proxyto' parameter.",
	    optional => 1,
	},
        permissions => {
	    type => 'object',
	    description => "Required access permissions. By default only 'root' is allowed to access this method.",
	    optional => 1,
	    additionalProperties => 0,
	    properties => {
	        description => {
	             description => "Describe access permissions.",
	             optional => 1,
	        },
                user => {
                    description => "A simply way to allow access for 'all' authenticated users. Value 'world' is used to allow access without credentials.", 
                    type => 'string', 
                    enum => ['all', 'world'],
                    optional => 1,
                },
                check => {
                    description => "Array of permission checks (prefix notation).",
                    type => 'array', 
                    optional => 1 
                },
            },
        },
        match_name => {
	    description => "Used internally",
	    optional => 1,
        },
        match_re => {
	    description => "Used internally",
	    optional => 1,
        },
	path => {
	    type =>  'string',
	    description => "path for URL matching (uri template)",
	},
        fragmentDelimiter => {
            type => 'string',
	    description => "A ways to override the default fragment delimiter '/'. This onyl works on a whole sub-class. You can set this to the empty string to match the whole rest of the URI.",            
	    optional => 1,
        },
	parameters => {
	    type => 'object',
	    description => "JSON Schema for parameters.",
	    optional => 1,
	},
	returns => {
	    type => 'object',
	    description => "JSON Schema for return value.",
	    optional => 1,
	},
        code => {
	    type => 'coderef',
	    description => "method implementaion (code reference)",
	    optional => 1,
        },
	subclass => {
	    type => 'string',
	    description => "Delegate call to this class (perl class string).",
	    optional => 1,
            requires => {
 		additionalProperties => 0,
		properties => {
                    subclass => {},
                    path => {},
                    match_name => {},
                    match_re => {},
                    fragmentDelimiter => { optional => 1 }
                }             
            },
	}, 
    },

};

sub validate_schema {
    my ($schema) = @_; 

    my $errmsg = "internal error - unable to verify schema\n";
    validate($schema, $default_schema, $errmsg);
}

sub validate_method_info {
    my $info = shift;

    my $errmsg = "internal error - unable to verify method info\n";
    validate($info, $method_schema, $errmsg);
 
    validate_schema($info->{parameters}) if $info->{parameters};
    validate_schema($info->{returns}) if $info->{returns};
}

# run a self test on load
# make sure we can verify the default schema 
validate_schema($default_schema_noref);
validate_schema($method_schema);

# and now some utility methods (used by pve api)
sub method_get_child_link {
    my ($info) = @_;

    return undef if !$info;

    my $schema = $info->{returns};
    return undef if !$schema || !$schema->{type} || $schema->{type} ne 'array';

    my $links = $schema->{links};
    return undef if !$links;

    my $found;
    foreach my $lnk (@$links) {
	if ($lnk->{href} && $lnk->{rel} && ($lnk->{rel} eq 'child')) {
	    $found = $lnk;
	    last;
	}
    }

    return $found;
}

# a way to parse command line parameters, using a 
# schema to configure Getopt::Long
sub get_options {
    my ($schema, $args, $arg_param, $fixed_param, $param_mapping_hash) = @_;

    if (!$schema || !$schema->{properties}) {
	raise("too many arguments\n", code => HTTP_BAD_REQUEST)
	    if scalar(@$args) != 0;
	return {};
    }

    my $list_param;
    if ($arg_param && !ref($arg_param)) {
	my $pd = $schema->{properties}->{$arg_param};
	die "expected list format $pd->{format}"
	    if !($pd && $pd->{format} && $pd->{format} =~ m/-list/);
	$list_param = $arg_param;
    }

    my @interactive = ();
    my @getopt = ();
    foreach my $prop (keys %{$schema->{properties}}) {
	my $pd = $schema->{properties}->{$prop};
	next if $list_param && $prop eq $list_param;
	next if defined($fixed_param->{$prop});

	my $mapping = $param_mapping_hash->{$prop};
	if ($mapping && $mapping->{interactive}) {
	    # interactive parameters such as passwords: make the argument
	    # optional and call the mapping function afterwards.
	    push @getopt, "$prop:s";
	    push @interactive, [$prop, $mapping->{func}];
	} elsif ($pd->{type} eq 'boolean') {
	    push @getopt, "$prop:s";
	} else {
	    if ($pd->{format} && $pd->{format} =~ m/-a?list/) {
		push @getopt, "$prop=s@";
	    } else {
		push @getopt, "$prop=s";
	    }
	}
    }

    Getopt::Long::Configure('prefix_pattern=(--|-)');

    my $opts = {};
    raise("unable to parse option\n", code => HTTP_BAD_REQUEST)
	if !Getopt::Long::GetOptionsFromArray($args, $opts, @getopt);

    if (@$args) {
	if ($list_param) {
	    $opts->{$list_param} = $args;
	    $args = [];
	} elsif (ref($arg_param)) {
	    foreach my $arg_name (@$arg_param) {
		if ($opts->{'extra-args'}) {
		    raise("internal error: extra-args must be the last argument\n", code => HTTP_BAD_REQUEST);
		}
		if ($arg_name eq 'extra-args') {
		    $opts->{'extra-args'} = $args;
		    $args = [];
		    next;
		}
		raise("not enough arguments\n", code => HTTP_BAD_REQUEST) if !@$args;
		$opts->{$arg_name} = shift @$args;
	    }
	    raise("too many arguments\n", code => HTTP_BAD_REQUEST) if @$args;
	} else {
	    raise("too many arguments\n", code => HTTP_BAD_REQUEST)
		if scalar(@$args) != 0;
	}
    } else {
	if (ref($arg_param)) {
	    foreach my $arg_name (@$arg_param) {
		if ($arg_name eq 'extra-args') {
		    $opts->{'extra-args'} = [];
		} else {
		    raise("not enough arguments\n", code => HTTP_BAD_REQUEST);
		}
	    }
	}
    }

    foreach my $entry (@interactive) {
	my ($opt, $func) = @$entry;
	my $pd = $schema->{properties}->{$opt};
	my $value = $opts->{$opt};
	if (defined($value) || !$pd->{optional}) {
	    $opts->{$opt} = $func->($value);
	}
    }

    # decode after Getopt as we are not sure how well it handles unicode
    foreach my $p (keys %$opts) {
	if (!ref($opts->{$p})) {
	    $opts->{$p} = decode('locale', $opts->{$p});
	} elsif (ref($opts->{$p}) eq 'ARRAY') {
	    my $tmp = [];
	    foreach my $v (@{$opts->{$p}}) {
		push @$tmp, decode('locale', $v);
	    }
	    $opts->{$p} = $tmp;
	} elsif (ref($opts->{$p}) eq 'SCALAR') {
	    $opts->{$p} = decode('locale', $$opts->{$p});
	} else {
	    raise("decoding options failed, unknown reference\n", code => HTTP_BAD_REQUEST);
	}
    }

    foreach my $p (keys %$opts) {
	if (my $pd = $schema->{properties}->{$p}) {
	    if ($pd->{type} eq 'boolean') {
		if ($opts->{$p} eq '') {
		    $opts->{$p} = 1;
		} elsif (defined(my $bool = parse_boolean($opts->{$p}))) {
		    $opts->{$p} = $bool;
		} else {
		    raise("unable to parse boolean option\n", code => HTTP_BAD_REQUEST);
		}
	    } elsif ($pd->{format}) {

		if ($pd->{format} =~ m/-list/) {
		    # allow --vmid 100 --vmid 101 and --vmid 100,101
		    # allow --dow mon --dow fri and --dow mon,fri
		    $opts->{$p} = join(",", @{$opts->{$p}}) if ref($opts->{$p}) eq 'ARRAY';
		} elsif ($pd->{format} =~ m/-alist/) {
		    # we encode array as \0 separated strings
		    # Note: CGI.pm also use this encoding
		    if (scalar(@{$opts->{$p}}) != 1) {
			$opts->{$p} = join("\0", @{$opts->{$p}});
		    } else {
			# st that split_list knows it is \0 terminated
			my $v = $opts->{$p}->[0];
			$opts->{$p} = "$v\0";
		    }
		}
	    }
	}	
    }

    foreach my $p (keys %$fixed_param) {
	$opts->{$p} = $fixed_param->{$p};
    }

    return $opts;
}

# A way to parse configuration data by giving a json schema
sub parse_config {
    my ($schema, $filename, $raw) = @_;

    # do fast check (avoid validate_schema($schema))
    die "got strange schema" if !$schema->{type} || 
	!$schema->{properties} || $schema->{type} ne 'object';

    my $cfg = {};

    while ($raw =~ /^\s*(.+?)\s*$/gm) {
	my $line = $1;

	next if $line =~ /^#/;

	if ($line =~ m/^(\S+?):\s*(.*)$/) {
	    my $key = $1;
	    my $value = $2;
	    if ($schema->{properties}->{$key} && 
		$schema->{properties}->{$key}->{type} eq 'boolean') {

		$value = parse_boolean($value) // $value;
	    }
	    $cfg->{$key} = $value;
	} else {
	    warn "ignore config line: $line\n"
	}
    }

    my $errors = {};
    check_prop($cfg, $schema, '', $errors);

    foreach my $k (keys %$errors) {
	warn "parse error in '$filename' - '$k': $errors->{$k}\n";
	delete $cfg->{$k};
    } 

    return $cfg;
}

# generate simple key/value file
sub dump_config {
    my ($schema, $filename, $cfg) = @_;

    # do fast check (avoid validate_schema($schema))
    die "got strange schema" if !$schema->{type} || 
	!$schema->{properties} || $schema->{type} ne 'object';

    validate($cfg, $schema, "validation error in '$filename'\n");

    my $data = '';

    foreach my $k (keys %$cfg) {
	$data .= "$k: $cfg->{$k}\n";
    }

    return $data;
}

# helpers used to generate our manual pages

my $find_schema_default_key = sub {
    my ($format) = @_;

    my $default_key;
    my $keyAliasProps = {};

    foreach my $key (keys %$format) {
	my $phash = $format->{$key};
	if ($phash->{default_key}) {
	    die "multiple default keys in schema ($default_key, $key)\n"
		if defined($default_key);
	    die "default key '$key' is an alias - this is not allowed\n"
		if defined($phash->{alias});
	    die "default key '$key' with keyAlias attribute is not allowed\n"
		if $phash->{keyAlias};
	    $default_key = $key;
	}
	my $key_alias = $phash->{keyAlias};
	die "found keyAlias without 'alias definition for '$key'\n"
	    if $key_alias && !$phash->{alias};

	if ($phash->{alias} && $key_alias) {
	    die "inconsistent keyAlias '$key_alias' definition"
		if defined($keyAliasProps->{$key_alias}) &&
		$keyAliasProps->{$key_alias} ne $phash->{alias};
	    $keyAliasProps->{$key_alias} = $phash->{alias};
	}
    }

    return wantarray ? ($default_key, $keyAliasProps) : $default_key;
};

sub generate_typetext {
    my ($format, $list_enums) = @_;

    my ($default_key, $keyAliasProps) = &$find_schema_default_key($format);

    my $res = '';
    my $add_sep = 0;

    my $add_option_string = sub {
	my ($text, $optional) = @_;

	if ($add_sep) {
	    $text = ",$text";
	    $res .= ' ';
	}
	$text = "[$text]" if $optional;
	$res .= $text;
	$add_sep = 1;
    };

    my $format_key_value = sub {
	my ($key, $phash) = @_;

	die "internal error" if defined($phash->{alias});

	my $keytext = $key;

	my $typetext = '';

	if (my $desc = $phash->{format_description}) {
	    $typetext .= "<$desc>";
	} elsif (my $text = $phash->{typetext}) {
	    $typetext .= $text;
	} elsif (my $enum = $phash->{enum}) {
	    if ($list_enums || (scalar(@$enum) <= 3)) {
		$typetext .= '<' . join('|', @$enum) . '>';
	    } else {
		$typetext .= '<enum>';
	    }
	} elsif ($phash->{type} eq 'boolean') {
	    $typetext .= '<1|0>';
	} elsif ($phash->{type} eq 'integer') {
	    $typetext .= '<integer>';
	} elsif ($phash->{type} eq 'number') {
	    $typetext .= '<number>';
	} else {
	    die "internal error: neither format_description nor typetext found for option '$key'";
	}

	if (defined($default_key) && ($default_key eq $key)) {
	    &$add_option_string("[$keytext=]$typetext", $phash->{optional});
	} else {
	    &$add_option_string("$keytext=$typetext", $phash->{optional});
	}
    };

    my $done = {};

    my $cond_add_key = sub {
	my ($key) = @_;

	return if $done->{$key}; # avoid duplicates

	$done->{$key} = 1;

	my $phash = $format->{$key};

	return if !$phash; # should not happen

	return if $phash->{alias};

	&$format_key_value($key, $phash);

    };

    &$cond_add_key($default_key) if defined($default_key);

    # add required keys first
    foreach my $key (sort keys %$format) {
	my $phash = $format->{$key};
	&$cond_add_key($key) if $phash && !$phash->{optional};
    }

    # add the rest
    foreach my $key (sort keys %$format) {
	&$cond_add_key($key);
    }

    foreach my $keyAlias (sort keys %$keyAliasProps) {
	&$add_option_string("<$keyAlias>=<$keyAliasProps->{$keyAlias }>", 1);
    }

    return $res;
}

sub print_property_string {
    my ($data, $format, $skip, $path) = @_;

    if (ref($format) ne 'HASH') {
	my $schema = get_format($format);
	die "not a valid format: $format\n" if !$schema;
	$format = $schema;
    }

    my $errors = {};
    check_object($path, $format, $data, undef, $errors);
    if (scalar(%$errors)) {
	raise "format error", errors => $errors;
    }

    my ($default_key, $keyAliasProps) = &$find_schema_default_key($format);

    my $res = '';
    my $add_sep = 0;

    my $add_option_string = sub {
	my ($text) = @_;

	$res .= ',' if $add_sep;
	$res .= $text;
	$add_sep = 1;
    };

    my $format_value = sub {
	my ($key, $value, $format) = @_;

	if (defined($format) && ($format eq 'disk-size')) {
	    return format_size($value);
	} else {
	    die "illegal value with commas for $key\n" if $value =~ /,/;
	    return $value;
	}
    };

    my $done = { map { $_ => 1 } @$skip };

    my $cond_add_key = sub {
	my ($key, $isdefault) = @_;

	return if $done->{$key}; # avoid duplicates

	$done->{$key} = 1;

	my $value = $data->{$key};

	return if !defined($value);

	my $phash = $format->{$key};

	# try to combine values if we have key aliases
	if (my $combine = $keyAliasProps->{$key}) {
	    if (defined(my $combine_value = $data->{$combine})) {
		my $combine_format = $format->{$combine}->{format};
		my $value_str = &$format_value($key, $value, $phash->{format});
		my $combine_str = &$format_value($combine, $combine_value, $combine_format);
		&$add_option_string("${value_str}=${combine_str}");
		$done->{$combine} = 1;
		return;
	    }
	}

	if ($phash && $phash->{alias}) {
	    $phash = $format->{$phash->{alias}};
	}

	die "invalid key '$key'\n" if !$phash;
	die "internal error" if defined($phash->{alias});

	my $value_str = &$format_value($key, $value, $phash->{format});
	if ($isdefault) {
	    &$add_option_string($value_str);
	} else {
	    &$add_option_string("$key=${value_str}");
	}
    };

    # add default key first
    &$cond_add_key($default_key, 1) if defined($default_key);

    # add required keys first
    foreach my $key (sort keys %$data) {
	my $phash = $format->{$key};
	&$cond_add_key($key) if $phash && !$phash->{optional};
    }

    # add the rest
    foreach my $key (sort keys %$data) {
	&$cond_add_key($key);
    }

    return $res;
}

sub schema_get_type_text {
    my ($phash, $style) = @_;

    my $type = $phash->{type} || 'string';

    if ($phash->{typetext}) {
	return $phash->{typetext};
    } elsif ($phash->{format_description}) {
	return "<$phash->{format_description}>";
    } elsif ($phash->{enum}) {
	return "<" . join(' | ', sort @{$phash->{enum}}) . ">";
    } elsif ($phash->{pattern}) {
	return $phash->{pattern};
    } elsif ($type eq 'integer' || $type eq 'number') {
	# NOTE: always access values as number (avoid converion to string)
	if (defined($phash->{minimum}) && defined($phash->{maximum})) {
	    return "<$type> (" . ($phash->{minimum} + 0) . " - " .
		($phash->{maximum} + 0) . ")";
	} elsif (defined($phash->{minimum})) {
	    return "<$type> (" . ($phash->{minimum} + 0) . " - N)";
	} elsif (defined($phash->{maximum})) {
	    return "<$type> (-N - " . ($phash->{maximum} + 0) . ")";
	}
    } elsif ($type eq 'string') {
	if (my $format = $phash->{format}) {
	    $format = get_format($format) if ref($format) ne 'HASH';
	    if (ref($format) eq 'HASH') {
		my $list_enums = 0;
		$list_enums = 1 if $style && $style eq 'config-sub';
		return generate_typetext($format, $list_enums);
	    }
	}
    }

    return "<$type>";
}

1;
