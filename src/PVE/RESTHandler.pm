package PVE::RESTHandler;

use strict;
no strict 'refs'; # our autoload requires this
use warnings;
use PVE::SafeSyslog;
use PVE::Exception qw(raise raise_param_exc);
use PVE::JSONSchema;
use PVE::Tools;
use HTTP::Status qw(:constants :is status_message);
use Text::Wrap;
use Clone qw(clone);

my $method_registry = {};
my $method_by_name = {};
my $method_path_lookup = {};

our $AUTOLOAD;  # it's a package global

sub api_clone_schema {
    my ($schema) = @_;

    my $res = {};
    my $ref = ref($schema);
    die "not a HASH reference" if !($ref && $ref eq 'HASH');

    foreach my $k (keys %$schema) {
	my $d = $schema->{$k};
	if ($k ne 'properties') {
	    $res->{$k} = ref($d) ? clone($d) : $d;
	    next;
	}
	# convert indexed parameters like -net\d+ to -net[n]
	foreach my $p (keys %$d) {
	    my $pd = $d->{$p};
	    if ($p =~ m/^([a-z]+)(\d+)$/) {
		my ($name, $idx) = ($1, $2);
		if ($idx == 0 && defined($d->{"${name}1"})) {
		    $p = "${name}[n]";
		} elsif (defined($d->{"${name}0"})) {
		    next; # only handle once for -xx0, but only if -xx0 exists
		}
	    }
	    my $tmp = ref($pd) ? clone($pd) : $pd;
	    # NOTE: add typetext property for more complex types, to
	    # make the web api viewer code simpler
	    if (!(defined($tmp->{enum}) || defined($tmp->{pattern}))) {
		my $typetext = PVE::JSONSchema::schema_get_type_text($tmp);
		if ($tmp->{type} && ($tmp->{type} ne $typetext)) {
		    $tmp->{typetext} = $typetext;
		}
	    }
	    $res->{$k}->{$p} = $tmp;
	}
    }

    return $res;
}

sub api_dump_full {
    my ($tree, $index, $class, $prefix) = @_;

    $prefix = '' if !$prefix;

    my $ma = $method_registry->{$class};

    foreach my $info (@$ma) {

	my $path = "$prefix/$info->{path}";
	$path =~ s/\/+$//;

	if ($info->{subclass}) {
	    api_dump_full($tree, $index, $info->{subclass}, $path);
	} else {
	    next if !$path;

	    # check if method is unique
	    my $realpath = $path;
	    $realpath =~ s/\{[^\}]+\}/\{\}/g;
	    my $fullpath = "$info->{method} $realpath";
	    die "duplicate path '$realpath'" if $index->{$fullpath};
	    $index->{$fullpath} = $info;

	    # insert into tree
	    my $treedir = $tree;
	    my $res;
	    my $sp = '';
	    foreach my $dir (split('/', $path)) {
		next if !$dir;
		$sp .= "/$dir";
		$res = (grep { $_->{text} eq $dir } @$treedir)[0];
		if ($res) {
		    $res->{children} = [] if !$res->{children};
		    $treedir = $res->{children};
		} else {
		    $res = {
			path => $sp,
			text => $dir,
			children => [],
		    };
		    push @$treedir, $res;
		    $treedir = $res->{children};
		}
	    }

	    if ($res) {
		my $data = {};
		foreach my $k (keys %$info) {
		    next if $k eq 'code' || $k eq "match_name" || $k eq "match_re" ||
			$k eq "path";

		    my $d = $info->{$k};
		    
		    if ($k eq 'parameters') {
			$data->{$k} = api_clone_schema($d);
		    } else {

			$data->{$k} = ref($d) ? clone($d) : $d;
		    }
		} 
		$res->{info}->{$info->{method}} = $data;
	    };
	}
    }
};

sub api_dump_cleanup_tree {
    my ($tree) = @_;

    foreach my $rec (@$tree) {
	delete $rec->{children} if $rec->{children} && !scalar(@{$rec->{children}});
	if ($rec->{children}) {
	    $rec->{leaf} = 0;
	    api_dump_cleanup_tree($rec->{children});
	} else {
	    $rec->{leaf} = 1;
	}
    }

}

sub api_dump {
    my ($class, $prefix) = @_;

    my $tree = [];

    my $index = {};
    api_dump_full($tree, $index, $class);
    api_dump_cleanup_tree($tree);
    return $tree;
};

sub validate_method_schemas {

    foreach my $class (keys %$method_registry) {
	my $ma = $method_registry->{$class};

	foreach my $info (@$ma) {
	    PVE::JSONSchema::validate_method_info($info);
	}
    }
}

sub register_method {
    my ($self, $info) = @_;

    my $match_re = [];
    my $match_name = [];

    my $errprefix;

    my $method;
    if ($info->{subclass}) {
	$errprefix = "register subclass $info->{subclass} at ${self}/$info->{path} -";
	$method = 'SUBCLASS';
    } else {
	$errprefix = "register method ${self}/$info->{path} -";
	$info->{method} = 'GET' if !$info->{method};
	$method = $info->{method};
    }

    $method_path_lookup->{$self} = {} if !defined($method_path_lookup->{$self});
    my $path_lookup = $method_path_lookup->{$self};

    die "$errprefix no path" if !defined($info->{path});
    
    foreach my $comp (split(/\/+/, $info->{path})) {
	die "$errprefix path compoment has zero length\n" if $comp eq '';
	my ($name, $regex);
	if ($comp =~ m/^\{(\w+)(:(.*))?\}$/) {
	    $name = $1;
	    $regex = $3 ? $3 : '\S+';
	    push @$match_re, $regex;
	    push @$match_name, $name;
	} else {
	    $name = $comp;
	    push @$match_re, $name;
	    push @$match_name, undef;
	}

	if ($regex) {
	    $path_lookup->{regex} = {} if !defined($path_lookup->{regex});	

	    my $old_name = $path_lookup->{regex}->{match_name};
	    die "$errprefix found changed regex match name\n"
		if defined($old_name) && ($old_name ne $name);
	    my $old_re = $path_lookup->{regex}->{match_re};
	    die "$errprefix found changed regex\n"
		if defined($old_re) && ($old_re ne $regex);
	    $path_lookup->{regex}->{match_name} = $name;
	    $path_lookup->{regex}->{match_re} = $regex;
	    
	    die "$errprefix path match error - regex and fixed items\n"
		if defined($path_lookup->{folders});

	    $path_lookup = $path_lookup->{regex};
	    
	} else {
	    $path_lookup->{folders}->{$name} = {} if !defined($path_lookup->{folders}->{$name});	

	    die "$errprefix path match error - regex and fixed items\n"
		if defined($path_lookup->{regex});

	    $path_lookup = $path_lookup->{folders}->{$name};
	}
    }

    die "$errprefix duplicate method definition\n" 
	if defined($path_lookup->{$method});

    if ($method eq 'SUBCLASS') {
	foreach my $m (qw(GET PUT POST DELETE)) {
	    die "$errprefix duplicate method definition SUBCLASS and $m\n" if $path_lookup->{$m};
	}
    }
    $path_lookup->{$method} = $info;

    $info->{match_re} = $match_re;
    $info->{match_name} = $match_name;

    $method_by_name->{$self} = {} if !defined($method_by_name->{$self});

    if ($info->{name}) {
	die "$errprefix method name already defined\n"
	    if defined($method_by_name->{$self}->{$info->{name}});

	$method_by_name->{$self}->{$info->{name}} = $info;
    }

    push @{$method_registry->{$self}}, $info;
}

sub DESTROY {}; # avoid problems with autoload

sub AUTOLOAD {
    my ($this) = @_;

    # also see "man perldiag"
 
    my $sub = $AUTOLOAD;
    (my $method = $sub) =~ s/.*:://;

    my $info = $this->map_method_by_name($method);

    *{$sub} = sub {
	my $self = shift;
	return $self->handle($info, @_);
    };
    goto &$AUTOLOAD;
}

sub method_attributes {
    my ($self) = @_;

    return $method_registry->{$self};
}

sub map_method_by_name {
    my ($self, $name) = @_;

    my $info = $method_by_name->{$self}->{$name};
    die "no such method '${self}::$name'\n" if !$info;

    return $info;
}

sub map_path_to_methods {
    my ($class, $stack, $uri_param, $pathmatchref) = @_;

    my $path_lookup = $method_path_lookup->{$class};

    # Note: $pathmatchref can be used to obtain path including
    # uri patterns like '/cluster/firewall/groups/{group}'.
    # Used by pvesh to display help
    if (defined($pathmatchref)) {
	$$pathmatchref = '' if !$$pathmatchref;
    }

    while (defined(my $comp = shift @$stack)) {
	return undef if !$path_lookup; # not registerd?
	if ($path_lookup->{regex}) {
	    my $name = $path_lookup->{regex}->{match_name};
	    my $regex = $path_lookup->{regex}->{match_re};

	    return undef if $comp !~ m/^($regex)$/;
	    $uri_param->{$name} = $1;
	    $path_lookup = $path_lookup->{regex};
	    $$pathmatchref .= '/{' . $name . '}' if defined($pathmatchref);
	} elsif ($path_lookup->{folders}) {
	    $path_lookup = $path_lookup->{folders}->{$comp};
	    $$pathmatchref .= '/' . $comp if defined($pathmatchref);
	} else {
	    die "internal error";
	}
 
	return undef if !$path_lookup;

	if (my $info = $path_lookup->{SUBCLASS}) {
	    $class = $info->{subclass};

	    my $fd = $info->{fragmentDelimiter};

	    if (defined($fd)) {
		# we only support the empty string '' (match whole URI)
		die "unsupported fragmentDelimiter '$fd'" 
		    if $fd ne '';

		$stack = [ join ('/', @$stack) ] if scalar(@$stack) > 1;
	    }
	    $path_lookup = $method_path_lookup->{$class};
	}
    }

    return undef if !$path_lookup;

    return ($class, $path_lookup);
}

sub find_handler {
    my ($class, $method, $path, $uri_param, $pathmatchref) = @_;

    my $stack = [ grep { length($_) > 0 }  split('\/+' , $path)]; # skip empty fragments

    my ($handler_class, $path_info);
    eval {
	($handler_class, $path_info) = $class->map_path_to_methods($stack, $uri_param, $pathmatchref);
    };
    my $err = $@;
    syslog('err', $err) if $err;

    return undef if !($handler_class && $path_info);

    my $method_info = $path_info->{$method};

    return undef if !$method_info;

    return ($handler_class, $method_info);
}

sub handle {
    my ($self, $info, $param) = @_;

    my $func = $info->{code};

    if (!($info->{name} && $func)) {
	raise("Method lookup failed ('$info->{name}')\n",
	      code => HTTP_INTERNAL_SERVER_ERROR);
    }

    if (my $schema = $info->{parameters}) {
	# warn "validate ". Dumper($param}) . "\n" . Dumper($schema);
	PVE::JSONSchema::validate($param, $schema);
	# untaint data (already validated)
	my $extra = delete $param->{'extra-args'};
	while (my ($key, $val) = each %$param) {
	    ($param->{$key}) = $val =~ /^(.*)$/s;
	}
	$param->{'extra-args'} = [map { /^(.*)$/ } @$extra] if $extra;
    }

    my $result = &$func($param); 

    # todo: this is only to be safe - disable?
    if (my $schema = $info->{returns}) {
	PVE::JSONSchema::validate($result, $schema, "Result verification failed\n");
    }

    return $result;
}

# format option, display type and description
# $name: option name
# $display_name: for example "-$name" of "<$name>", pass undef to use "$name:"
# $phash: json schema property hash
# $format: 'asciidoc', 'short', 'long' or 'full'
# $style: 'config', 'config-sub', 'arg' or 'fixed'
# $mapdef: parameter mapping ({ desc => XXX, func => sub {...} })
my $get_property_description = sub {
    my ($name, $style, $phash, $format, $hidepw, $mapdef) = @_;

    my $res = '';

    $format = 'asciidoc' if !defined($format);

    my $descr = $phash->{description} || "no description available";

    if ($phash->{verbose_description} &&
	($style eq 'config' || $style eq 'config-sub')) {
	$descr = $phash->{verbose_description};
    }

    chomp $descr;

    my $type_text = PVE::JSONSchema::schema_get_type_text($phash, $style);

    if ($hidepw && $name eq 'password') {
	$type_text = '';
    }

    if ($mapdef && $phash->{type} eq 'string') {
	$type_text = $mapdef->{desc};
    }

    if ($format eq 'asciidoc') {

	if ($style eq 'config') {
	    $res .= "`$name`: ";
	} elsif ($style eq 'config-sub') {
	    $res .= "`$name`=";
	} elsif ($style eq 'arg') {
	    $res .= "`--$name` ";
	} elsif ($style eq 'fixed') {
	    $res .= "`<$name>`: ";
	} else {
	    die "unknown style '$style'";
	}

	$res .= "`$type_text` " if $type_text;

	if (defined(my $dv = $phash->{default})) {
	    $res .= "('default =' `$dv`)";
	}

	if ($style eq 'config-sub') {
	    $res .= ";;\n\n";
	} else {
	    $res .= "::\n\n";
	}

	my $wdescr = $descr;
	chomp $wdescr;
	$wdescr =~ s/^$/+/mg;

	$res .= $wdescr . "\n";

	if (my $req = $phash->{requires}) {
	    my $tmp .= ref($req) ? join(', ', @$req) : $req;
	    $res .= "+\nNOTE: Requires option(s): `$tmp`\n";
	}
	$res .= "\n";

    } elsif ($format eq 'short' || $format eq 'long' || $format eq 'full') {

	my $defaulttxt = '';
	if (defined(my $dv = $phash->{default})) {
	    $defaulttxt = "   (default=$dv)";
	}

	my $display_name;
	if ($style eq 'config') {
	    $display_name = "$name:";
	} elsif ($style eq 'arg') {
	    $display_name = "-$name";
	} elsif ($style eq 'fixed') {
	    $display_name = "<$name>";
	} else {
	    die "unknown style '$style'";
	}

	my $tmp = sprintf "  %-10s %s$defaulttxt\n", $display_name, "$type_text";
	my $indend = "             ";

	$res .= Text::Wrap::wrap('', $indend, ($tmp));
	$res .= "\n",
	$res .= Text::Wrap::wrap($indend, $indend, ($descr)) . "\n\n";

	if (my $req = $phash->{requires}) {
	    my $tmp = "Requires option(s): ";
	    $tmp .= ref($req) ? join(', ', @$req) : $req;
	    $res .= Text::Wrap::wrap($indend, $indend, ($tmp)). "\n\n";
	}

    } else {
	die "unknown format '$format'";
    }

    return $res;
};

# translate parameter mapping definition
# $mapping_array is a array which can contain:
#   strings ... in that case we assume it is a parameter name, and
#      we want to load that parameter from a file
#   [ param_name, func, desc] ... allows you to specify a arbitrary
#      mapping func for any param
#
# Returns: a hash indexed by parameter_name,
# i.e.  { param_name => { func => .., desc => ... } }
my $compute_param_mapping_hash = sub {
    my ($mapping_array) = @_;

    my $res = {};

    return $res if !defined($mapping_array);

    foreach my $item (@$mapping_array) {
	my ($name, $func, $desc, $interactive);
	if (ref($item) eq 'ARRAY') {
	    ($name, $func, $desc, $interactive) = @$item;
	} else {
	    $name = $item;
	    $func = sub { return PVE::Tools::file_get_contents($_[0]) };
	}
	$desc //= '<filepath>';
	$res->{$name} = { desc => $desc, func => $func, interactive => $interactive };
    }

    return $res;
};

# generate usage information for command line tools
#
# $name        ... the name of the method
# $prefix      ... usually something like "$exename $cmd" ('pvesm add')
# $arg_param   ... list of parameters we want to get as ordered arguments 
#                  on the command line (or single parameter name for lists)
# $fixed_param ... do not generate and info about those parameters
# $format:
#   'long'     ... default (text, list all options)
#   'short'    ... command line only (text, one line)
#   'full'     ... text, include description
#   'asciidoc' ... generate asciidoc for man pages (like 'full')
# $hidepw      ... hide password option (use this if you provide a read passwork callback)
# $param_mapping_func ... mapping for string parameters to file path parameters
sub usage_str {
    my ($self, $name, $prefix, $arg_param, $fixed_param, $format, $hidepw, $param_mapping_func) = @_;

    $format = 'long' if !$format;

    my $info = $self->map_method_by_name($name);
    my $schema = $info->{parameters};
    my $prop = $schema->{properties};

    my $out = '';

    my $arg_hash = {};

    my $args = '';

    $arg_param = [ $arg_param ] if $arg_param && !ref($arg_param);

    foreach my $p (@$arg_param) {
	next if !$prop->{$p}; # just to be sure
	my $pd = $prop->{$p};

	$arg_hash->{$p} = 1;
	$args .= " " if $args;
	if ($pd->{format} && $pd->{format} =~ m/-list/) {
	    $args .= "{<$p>}";
	} else {
	    $args .= $pd->{optional} ? "[<$p>]" : "<$p>";
	}
    }

    my $argdescr = '';
    foreach my $k (@$arg_param) {
	next if defined($fixed_param->{$k}); # just to be sure
	next if !$prop->{$k}; # just to be sure
	$argdescr .= &$get_property_description($k, 'fixed', $prop->{$k}, $format, 0);
    }

    my $idx_param = {}; # -vlan\d+ -scsi\d+

    my $opts = '';
    foreach my $k (sort keys %$prop) {
	next if $arg_hash->{$k};
	next if defined($fixed_param->{$k});

	my $type_text = $prop->{$k}->{type} || 'string';

	next if $hidepw && ($k eq 'password') && !$prop->{$k}->{optional};

	my $base = $k;
	if ($k =~ m/^([a-z]+)(\d+)$/) {
	    my ($name, $idx) = ($1, $2);
	    next if $idx_param->{$name};
	    if ($idx == 0 && defined($prop->{"${name}1"})) {
		$idx_param->{$name} = 1;
		$base = "${name}[n]";
	    }
	}

	my $param_mapping_hash = $compute_param_mapping_hash->(&$param_mapping_func($name))
	    if $param_mapping_func;

	$opts .= &$get_property_description($base, 'arg', $prop->{$k}, $format,
					    $hidepw, $param_mapping_hash->{$k});

	if (!$prop->{$k}->{optional}) {
	    $args .= " " if $args;
	    $args .= "--$base <$type_text>"
	}
    } 

    if ($format eq 'asciidoc') {
	$out .= "*${prefix}*";
	$out .= " `$args`" if $args;
	$out .= $opts ? " `[OPTIONS]`\n" : "\n";
    } else {
	$out .= "USAGE: " if $format ne 'short';
	$out .= "$prefix $args";
	$out .= $opts ? " [OPTIONS]\n" : "\n";
    }

    return $out if $format eq 'short';

    if ($info->{description}) {
	if ($format eq 'asciidoc') {
	    my $desc = Text::Wrap::wrap('', '', ($info->{description}));
	    $out .= "\n$desc\n\n";
	} elsif ($format eq 'full') {
	    my $desc = Text::Wrap::wrap('  ', '  ', ($info->{description}));
	    $out .= "\n$desc\n\n";
	}
    }

    $out .= $argdescr if $argdescr;

    $out .= $opts if $opts;

    return $out;
}

# generate docs from JSON schema properties
sub dump_properties {
    my ($prop, $format, $style, $filterFn) = @_;

    my $raw = '';

    $style //= 'config';
    
    my $idx_param = {}; # -vlan\d+ -scsi\d+

    foreach my $k (sort keys %$prop) {
	my $phash = $prop->{$k};

	next if defined($filterFn) && &$filterFn($k, $phash);
	next if $phash->{alias};

	my $base = $k;
	if ($k =~ m/^([a-z]+)(\d+)$/) {
	    my ($name, $idx) = ($1, $2);
	    next if $idx_param->{$name};
	    if ($idx == 0 && defined($prop->{"${name}1"})) {
		$idx_param->{$name} = 1;
		$base = "${name}[n]";
	    }
	}

	$raw .= &$get_property_description($base, $style, $phash, $format, 0);

	next if $style ne 'config';

	my $prop_fmt = $phash->{format};
	next if !$prop_fmt;

	if (ref($prop_fmt) ne 'HASH') {
	    $prop_fmt = PVE::JSONSchema::get_format($prop_fmt);
	}

	next if !(ref($prop_fmt) && (ref($prop_fmt) eq 'HASH'));

	$raw .= dump_properties($prop_fmt, $format, 'config-sub')
	
    }

    return $raw;
}

my $replace_file_names_with_contents = sub {
    my ($param, $param_mapping_hash) = @_;

    while (my ($k, $d) = each %$param_mapping_hash) {
	next if $d->{interactive}; # handled by the JSONSchema's get_options code
	$param->{$k} = $d->{func}->($param->{$k})
	    if defined($param->{$k});
    }

    return $param;
};

sub cli_handler {
    my ($self, $prefix, $name, $args, $arg_param, $fixed_param, $read_password_func, $param_mapping_func) = @_;

    my $info = $self->map_method_by_name($name);

    my $res;
    eval {
	my $param_mapping_hash = $compute_param_mapping_hash->($param_mapping_func->($name)) if $param_mapping_func;
	my $param = PVE::JSONSchema::get_options($info->{parameters}, $args, $arg_param, $fixed_param, $read_password_func, $param_mapping_hash);

	if (defined($param_mapping_hash)) {
	    &$replace_file_names_with_contents($param, $param_mapping_hash);
	}

	$res = $self->handle($info, $param);
    };
    if (my $err = $@) {
	my $ec = ref($err);

	die $err if !$ec || $ec ne "PVE::Exception" || !$err->is_param_exc();
	
	$err->{usage} = $self->usage_str($name, $prefix, $arg_param, $fixed_param, 'short', $read_password_func, $param_mapping_func);

	die $err;
    }

    return $res;
}

# utility methods
# note: this modifies the original hash by adding the id property
sub hash_to_array {
    my ($hash, $idprop) = @_;

    my $res = [];
    return $res if !$hash;

    foreach my $k (keys %$hash) {
	$hash->{$k}->{$idprop} = $k;
	push @$res, $hash->{$k};
    }

    return $res;
}

1;
