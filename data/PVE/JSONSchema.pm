package PVE::JSONSchema;

use warnings;
use strict;
use Storable; # for dclone
use Getopt::Long;
use Devel::Cycle -quiet; # todo: remove?
use PVE::Tools qw(split_list);
use PVE::Exception qw(raise);
use HTTP::Status qw(:constants);

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
    die "no such standard option\n" if !$std;

    my $res = $base || {};

    foreach my $opt (keys %$std) {
	next if $res->{$opt};
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

my $format_list = {};

sub register_format {
    my ($format, $code) = @_;

    die "JSON schema format '$format' already registered\n" 
	if $format_list->{$format};

    $format_list->{$format} = $code;
}

# register some common type for pve

register_format('string', sub {}); # allow format => 'string-list'

register_format('pve-configid', \&pve_verify_configid);
sub pve_verify_configid {
    my ($id, $noerr) = @_;
 
    if ($id !~ m/^[a-z][a-z0-9_]+$/i) {
	return undef if $noerr;
	die "invalid cofiguration ID '$id'\n"; 
    }
    return $id;
}

register_format('pve-vmid', \&pve_verify_vmid);
sub pve_verify_vmid {
    my ($vmid, $noerr) = @_;

    if ($vmid !~ m/^[1-9][0-9]+$/) {
	return undef if $noerr;
	die "value does not look like a valid VM ID\n";
    }
    return $vmid;
}

register_format('pve-node', \&pve_verify_node_name);
sub pve_verify_node_name {
    my ($node, $noerr) = @_;

    # todo: use better regex ?
    if ($node !~ m/^[A-Za-z][[:alnum:]\-]*[[:alnum:]]+$/) {
	return undef if $noerr;
	die "value does not look like a valid node name\n";
    }
    return $node;
}

register_format('ipv4', \&pve_verify_ipv4);
sub pve_verify_ipv4 {
    my ($ipv4, $noerr) = @_;

   if ($ipv4 !~ m/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/ ||
       !(($1 > 0) && ($1 < 255) &&
	 ($2 <= 255) && ($3 <= 255) && 
	 ($4 > 0) && ($4 < 255)))  {
	   return undef if $noerr;
	die "value does not look like a valid IP address\n";
    }
    return $ipv4;
}
register_format('ipv4mask', \&pve_verify_ipv4mask);
sub pve_verify_ipv4mask {
    my ($mask, $noerr) = @_;

    if ($mask !~ m/^255\.255\.(\d{1,3})\.(\d{1,3})$/ ||
	!(($1 <= 255) && ($2 <= 255)))  {
	return undef if $noerr;
	die "value does not look like a valid IP netmask\n";
    }
    return $mask;
}

register_format('email', \&pve_verify_email);
sub pve_verify_email {
    my ($email, $noerr) = @_;

    # we use same regex as extjs Ext.form.VTypes.email
    if ($email !~ /^(\w+)([\-+.][\w]+)*@(\w[\-\w]*\.){1,5}([A-Za-z]){2,6}$/) {
	   return undef if $noerr;
	   die "value does not look like a valid email address\n";
    }
    return $email;
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

sub check_format {
    my ($format, $value) = @_;

    return if $format eq 'regex';

    if ($format =~ m/^(.*)-list$/) {
	
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

	&$code($value);
    }
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
			return 0;
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
			      "missing property - '$newpath' requiers this property");
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
	if (!$schema->{optional}) {
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
	    eval { check_format($format, $value); };
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
        title => {
     	    type => "string",
	    optional => 1,
     	    description => "This provides the title of the property",
        },
        requires => {
     	    type => [ "string", "object" ],
	    optional => 1,
     	    description => "indicates a required property or a schema that must be validated if this property is present",
        },
        format => {
     	    type => "string",
	    optional => 1,
     	    description => "This indicates what format the data is among some predefined formats which may include:\n\ndate - a string following the ISO format \naddress \nschema - a schema definition object \nperson \npage \nhtml - a string representing HTML",
        },
	default => {
	    type => "any",
	    optional => 1,
	    description => "This indicates the default for the instance property."
	},
        disallow => {
     	    type => "object",
	    optional => 1,
     	    description => "This attribute may take the same values as the \"type\" attribute, however if the instance matches the type or if this value is an array and the instance matches any type or schema in the array, than this instance is not valid.",
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
	proxyto => {
	    type =>  'string',
	    description => "A parameter name. If specified, all calls to this method are proxied to the host contained in that parameter.",
	    optional => 1,
	},
        permissions => {
	    type => 'object',
	    description => "Required access permissions. By default only 'root' is allowed to access this method.",
	    optional => 1,
	    additionalProperties => 0,
	    properties => {
                user => {
                    description => "A simply way to allow access for 'all' users. The special value 'arg' allows access for the user specified in the 'username' parameter. This is useful to allow access to things owned by a user, like changing the user password. Value 'world' is used to allow access without credentials.", 
                    type => 'string', 
                    enum => ['all', 'arg', 'world'],
                    optional => 1,
                },
                path => { type => 'string', optional => 1, requires => 'privs' },
                privs => { type => 'array', optional => 1, requires => 'path' },
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
    my ($schema, $args, $uri_param, $pwcallback, $list_param) = @_;

    if (!$schema || !$schema->{properties}) {
	raise("too many arguments\n", code => HTTP_BAD_REQUEST)
	    if scalar(@$args) != 0;
	return {};
    }

    my @getopt = ();
    foreach my $prop (keys %{$schema->{properties}}) {
	my $pd = $schema->{properties}->{$prop};
	next if $prop eq $list_param;
	next if defined($uri_param->{$prop});

	if ($prop eq 'password' && $pwcallback) {
	    # we do not accept plain password on input line, instead
	    # we turn this into a boolean option and ask for password below
	    # using $pwcallback() (for security reasons).
	    push @getopt, "$prop";
	} elsif ($pd->{type} eq 'boolean') {
	    push @getopt, "$prop:s";
	} else {
	    if ($pd->{format} && $pd->{format} =~ m/-list/) {
		push @getopt, "$prop=s@";
	    } else {
		push @getopt, "$prop=s";
	    }
	}
    }

    my $opts = {};
    raise("unable to parse option\n", code => HTTP_BAD_REQUEST)
	if !Getopt::Long::GetOptionsFromArray($args, $opts, @getopt);
    
    if ($list_param) {
	my $pd = $schema->{properties}->{$list_param} ||
	    die "no schema for list_param";

	$opts->{$list_param} = $args;
	$args = [];
    }

    raise("too many arguments\n", code => HTTP_BAD_REQUEST)
	if scalar(@$args) != 0;

    if (my $pd = $schema->{properties}->{password}) {
	if ($pd->{type} ne 'boolean' && $pwcallback) {
	    if ($opts->{password} || !$pd->{optional}) {
		$opts->{password} = &$pwcallback(); 
	    }
	}
    }
    
    foreach my $p (keys %$opts) {
	if (my $pd = $schema->{properties}->{$p}) {
	    if ($pd->{type} eq 'boolean') {
		if ($opts->{$p} eq '') {
		    $opts->{$p} = 1;
		} elsif ($opts->{$p} =~ m/^(1|true|yes|on)$/i) {
		    $opts->{$p} = 1;
		} elsif ($opts->{$p} =~ m/^(0|false|no|off)$/i) {
		    $opts->{$p} = 0;
		} else {
		    raise("unable to parse boolean option\n", code => HTTP_BAD_REQUEST);
		}
	    } elsif ($pd->{format} && $pd->{format} =~ m/-list/) {

		if ($pd->{format} eq 'pve-vmid-list') {
		    # allow --vmid 100 --vmid 101 and --vmid 100,101
		    $opts->{$p} = join(",", @{$opts->{$p}});
		} else {
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

    foreach my $p (keys %$uri_param) {
	$opts->{$p} = $uri_param->{$p};
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

    while ($raw && $raw =~ s/^(.*?)(\n|$)//) {
	my $line = $1;
 
	next if $line =~ m/^\#/; # skip comment lines
	next if $line =~ m/^\s*$/; # skip empty lines

	if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
	    my $key = $1;
	    my $value = $2;
	    if ($schema->{properties}->{$key} && 
		$schema->{properties}->{$key}->{type} eq 'boolean') {

		$value = 1 if $value =~ m/^(1|on|yes|true)$/i; 
	        $value = 0 if $value =~ m/^(0|off|no|false)$/i; 
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

1;
