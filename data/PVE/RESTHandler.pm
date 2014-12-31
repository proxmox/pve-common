package PVE::RESTHandler;

use strict;
no strict 'refs'; # our autoload requires this
use warnings;
use PVE::SafeSyslog;
use PVE::Exception qw(raise raise_param_exc);
use PVE::JSONSchema;
use PVE::PodParser;
use HTTP::Status qw(:constants :is status_message);
use Text::Wrap;
use Storable qw(dclone);

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
	    $res->{$k} = ref($d) ? dclone($d) : $d;
	    next;
	}
	# convert indexed parameters like -net\d+ to -net[n]
	foreach my $p (keys %$d) {
	    my $pd = $d->{$p};
	    if ($p =~ m/^([a-z]+)(\d+)$/) {
		if ($2 == 0) {
		    $p = "$1\[n\]";
		} else {
		    next;
		}
	    }
	    $res->{$k}->{$p} = ref($pd) ? dclone($pd) : $pd;
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

			$data->{$k} = ref($d) ? dclone($d) : $d;
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

sub register_page_formatter {
    my ($self, %config) = @_;

    my $format = $config{format} ||
	die "missing format";

    my $path = $config{path} ||
	die "missing path";

    my $method = $config{method} ||
	die "missing method";
	
    my $code = $config{code} ||
	die "missing formatter code";
    
    my $uri_param = {};
    my ($handler, $info) = $self->find_handler($method, $path, $uri_param);
    die "unabe to find handler for '$method: $path'" if !($handler && $info);

    die "duplicate formatter for '$method: $path'" 
	if $info->{formatter} && $info->{formatter}->{$format};

    $info->{formatter}->{$format} = $code;
}

sub DESTROY {}; # avoid problems with autoload

sub AUTOLOAD {
    my ($this) = @_;

    # also see "man perldiag"
 
    my $sub = $AUTOLOAD;
    (my $method = $sub) =~ s/.*:://;

    $method =~ s/.*:://;

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
	while (my ($key, $val) = each %$param) {
	    ($param->{$key}) = $val =~ /^(.*)$/s;
	}
    }

    my $result = &$func($param); 

    # todo: this is only to be safe - disable?
    if (my $schema = $info->{returns}) {
	PVE::JSONSchema::validate($result, $schema, "Result verification vailed\n");
    }

    return $result;
}

# generate usage information for command line tools
#
# $name        ... the name of the method
# $prefix      ... usually something like "$exename $cmd" ('pvesm add')
# $arg_param   ... list of parameters we want to get as ordered arguments 
#                  on the command line (or single parameter name for lists)
# $fixed_param ... do not generate and info about those parameters
# $format:
#   'long'     ... default (list all options)
#   'short'    ... command line only (one line)
#   'full'     ... also include description
# $hidepw      ... hide password option (use this if you provide a read passwork callback)
sub usage_str {
    my ($self, $name, $prefix, $arg_param, $fixed_param, $format, $hidepw) = @_;

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

    my $get_prop_descr = sub {
	my ($k, $display_name) = @_;
 
	my $phash = $prop->{$k};

	my $res = '';
	
	my $descr = $phash->{description} || "no description available";
	chomp $descr;

	my $type = PVE::PodParser::schema_get_type_text($phash);

	if ($hidepw && $k eq 'password') {
	    $type = '';
	}
	
	my $defaulttxt = '';
	if (defined(my $dv = $phash->{default})) {
	    $defaulttxt = "   (default=$dv)";
	}
	my $tmp = sprintf "  %-10s %s$defaulttxt\n", $display_name, "$type";
	my $indend = "             ";

	$res .= Text::Wrap::wrap('', $indend, ($tmp));
	$res .= "\n",
	$res .= Text::Wrap::wrap($indend, $indend, ($descr)) . "\n\n";

	if (my $req = $phash->{requires}) {
	    my $tmp = "Requires option(s): ";
	    $tmp .= ref($req) ? join(', ', @$req) : $req;
	    $res .= Text::Wrap::wrap($indend, $indend, ($tmp)). "\n\n";
	}

	return $res;
    };

    my $argdescr = '';
    foreach my $k (@$arg_param) {
	next if defined($fixed_param->{$k}); # just to be sure
	next if !$prop->{$k}; # just to be sure
	$argdescr .= &$get_prop_descr($k, "<$k>");
    }

    my $idx_param = {}; # -vlan\d+ -scsi\d+

    my $opts = '';
    foreach my $k (sort keys %$prop) {
	next if $arg_hash->{$k};
	next if defined($fixed_param->{$k});

	my $type = $prop->{$k}->{type} || 'string';

	next if $hidepw && ($k eq 'password') && !$prop->{$k}->{optional};

	my $base = $k;
	if ($k =~ m/^([a-z]+)(\d+)$/) {
	    my $name = $1;
	    next if $idx_param->{$name};
	    $idx_param->{$name} = 1;
	    $base = "${name}[n]";
	}

	$opts .= &$get_prop_descr($k, "-$base");

	if (!$prop->{$k}->{optional}) {
	    $args .= " " if $args;
	    $args .= "-$base <$type>"
	}
    } 

    $out .= "USAGE: " if $format ne 'short';

    $out .= "$prefix $args";

    $out .= $opts ? " [OPTIONS]\n" : "\n";

    return $out if $format eq 'short';

    if ($info->{description} && $format eq 'full') {
	my $desc = Text::Wrap::wrap('  ', '  ', ($info->{description}));
	$out .= "\n$desc\n\n";
    }

    $out .= $argdescr if $argdescr;

    $out .= $opts if $opts;

    return $out;
}

sub cli_handler {
    my ($self, $prefix, $name, $args, $arg_param, $fixed_param, $pwcallback) = @_;

    my $info = $self->map_method_by_name($name);

    my $res;
    eval {
	my $param = PVE::JSONSchema::get_options($info->{parameters}, $args, $arg_param, $fixed_param, $pwcallback);
	$res = $self->handle($info, $param);
    };
    if (my $err = $@) {
	my $ec = ref($err);

	die $err if !$ec || $ec ne "PVE::Exception" || !$err->is_param_exc();
	
	$err->{usage} = $self->usage_str($name, $prefix, $arg_param, $fixed_param, 'short', $pwcallback);

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
