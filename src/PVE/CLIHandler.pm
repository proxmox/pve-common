package PVE::CLIHandler;

use strict;
use warnings;
use JSON;

use PVE::SafeSyslog;
use PVE::Exception qw(raise raise_param_exc);
use PVE::RESTHandler;
use PVE::PTY;
use PVE::INotify;
use PVE::CLIFormatter;

use base qw(PVE::RESTHandler);

# $cmddef defines which (sub)commands are available in a specific CLI class.
# A real command is always an array consisting of its class, name, array of
# position fixed (required) parameters and hash of predefined parameters when
# mapping a CLI command t o an API call. Optionally an output method can be
# passed at the end, e.g., for formatting or transformation purpose, and
# a schema of additional properties/arguments which are added to
# the method schema and gets passed to the formatter.
#
# [class, name, fixed_params, API_pre-set params, output_sub ]
#
# In case of so called 'simple commands', the $cmddef can be also just an
# array.
#
# Examples:
# $cmddef = {
#     command => [ 'PVE::API2::Class', 'command', [ 'arg1', 'arg2' ], { node => $nodename } ],
#     do => {
#         this => [ 'PVE::API2::OtherClass', 'method', [ 'arg1' ], undef, sub {
#             my ($res) = @_;
#             print "$res\n";
#         }],
#         that => [ 'PVE::API2::OtherClass', 'subroutine' [] ],
#     },
#     dothat => { alias => 'do that' },
# }
my $cmddef;
my $exename;
my $cli_handler_class;

my $standard_mappings = {
    'pve-password' => {
	name => 'password',
	desc => '<password>',
	interactive => 1,
	func => sub {
	    my ($value) = @_;
	    return $value if $value;
	    return PVE::PTY::get_confirmed_password();
	},
    },
};
sub get_standard_mapping {
    my ($name, $base) = @_;

    my $std = $standard_mappings->{$name};
    die "no such standard mapping '$name'\n" if !$std;

    my $res = $base || {};

    foreach my $opt (keys %$std) {
	next if defined($res->{$opt});
	$res->{$opt} = $std->{$opt};
    }

    return $res;
}

my $gen_param_mapping_func = sub {
    my ($cli_handler_class) = @_;

    my $param_mapping = $cli_handler_class->can('param_mapping');

    if (!$param_mapping) {
	my $read_password = $cli_handler_class->can('read_password');
	my $string_param_mapping = $cli_handler_class->can('string_param_file_mapping');

	return $string_param_mapping if !$read_password;

	$param_mapping = sub {
	    my ($name) = @_;

	    my $password_map = get_standard_mapping('pve-password', {
		func => $read_password
	    });
	    my $map = $string_param_mapping ? $string_param_mapping->($name) : [];
	    return [@$map, $password_map];
	};
    }

    return $param_mapping;
};

my $assert_initialized = sub {
    my @caller = caller;
    die "$caller[0]:$caller[2] - not initialized\n"
	if !($cmddef && $exename && $cli_handler_class);
};

my $abort = sub {
    my ($reason, $cmd) = @_;
    print_usage_short (\*STDERR, $reason, $cmd);
    exit (-1);
};

my $expand_command_name = sub {
    my ($def, $cmd) = @_;

    return $cmd if exists $def->{$cmd}; # command is already complete

    my $is_alias = sub { ref($_[0]) eq 'HASH' && exists($_[0]->{alias}) };
    my @expanded = grep { /^\Q$cmd\E/ && !$is_alias->($def->{$_}) } keys %$def;

    return $expanded[0] if scalar(@expanded) == 1; # enforce exact match

    return undef;
};

my $get_commands = sub {
    my $def = shift // die "no command definition passed!";
    return [ grep { !(ref($def->{$_}) eq 'HASH' && defined($def->{$_}->{alias})) } sort keys %$def ];
};

my $complete_command_names = sub { $get_commands->($cmddef) };

# traverses the command definition using the $argv array, resolving one level
# of aliases.
# Returns the matching (sub) command and its definition, and argument array for
# this (sub) command and a hash where we marked which (sub) commands got
# expanded (e.g. st => status) while traversing
sub resolve_cmd {
    my ($argv, $is_alias) = @_;

    my ($def, $cmd) = ($cmddef, $argv);
    my $cmdstr = $exename;

    if (ref($argv) eq 'ARRAY') {
	my $expanded_last_arg;
	my $last_arg_id = scalar(@$argv) - 1;

	for my $i (0..$last_arg_id) {
	    $cmd = $expand_command_name->($def, $argv->[$i]);
	    if (defined($cmd)) {
		# If the argument was expanded (or was already complete) and it
		# is the final argument, tell our caller about it:
		$expanded_last_arg = $cmd if $i == $last_arg_id;
	    } else {
		# Otherwise continue with the unexpanded version of it.
		$cmd = $argv->[$i]; 
	    }
	    $cmdstr .= " $cmd";
	    $def = $def->{$cmd};
	    last if !defined($def);

	    if (ref($def) eq 'ARRAY') {
		# could expand to a real command, rest of $argv are its arguments
		my $cmd_args = [ @$argv[$i+1..$last_arg_id] ];
		return ($cmd, $def, $cmd_args, $expanded_last_arg, $cmdstr);
	    }

	    if (defined($def->{alias})) {
		die "alias loop detected for '$cmd'" if $is_alias; # avoids cycles
		# replace aliased (sub)command with the expanded aliased command
		splice @$argv, $i, 1, split(/ +/, $def->{alias});
		return resolve_cmd($argv, 1);
	    }
	}
	# got either a special command (bashcomplete, verifyapi) or an unknown
	# cmd, just return first entry as cmd and the rest of $argv as cmd_arg
	my $cmd_args = [ @$argv[1..$last_arg_id] ];
	return ($argv->[0], $def, $cmd_args, $expanded_last_arg, $cmdstr);
    }
    return ($cmd, $def, undef, undef, $cmdstr);
}

sub generate_usage_str {
    my ($format, $cmd, $indent, $separator, $sortfunc) = @_;

    $assert_initialized->();
    die 'format required' if !$format;

    $sortfunc //= sub { sort keys %{$_[0]} };
    $separator //= '';
    $indent //= '';

    my $param_cb = $gen_param_mapping_func->($cli_handler_class);

    my ($subcmd, $def, undef, undef, $cmdstr) = resolve_cmd($cmd);
    $abort->("unknown command '$cmdstr'") if !defined($def) && ref($cmd) eq 'ARRAY';

    my $generate;
    $generate = sub {
	my ($indent, $separator, $def, $prefix) = @_;

	my $str = '';
	if (ref($def) eq 'HASH') {
	    my $oldclass = undef;
	    foreach my $cmd (&$sortfunc($def)) {

		if (ref($def->{$cmd}) eq 'ARRAY') {
		    my ($class, $name, $arg_param, $fixed_param, undef, $formatter_properties) = @{$def->{$cmd}};

		    $str .= $separator if $oldclass && $oldclass ne $class;
		    $str .= $indent;
		    $str .= $class->usage_str($name, "$prefix $cmd", $arg_param,
		                              $fixed_param, $format, $param_cb, $formatter_properties);
		    $oldclass = $class;

		} elsif (defined($def->{$cmd}->{alias}) && ($format eq 'asciidoc')) {

		    $str .= "*$prefix $cmd*\n\nAn alias for '$exename $def->{$cmd}->{alias}'.\n\n";

		} else {
		    next if $def->{$cmd}->{alias};

		    my $substr = $generate->($indent, $separator, $def->{$cmd}, "$prefix $cmd");
		    if ($substr) {
			$substr .= $separator if $substr !~ /\Q$separator\E{2}/;
			$str .= $substr;
		    }
		}

	    }
	} else {
	    my ($class, $name, $arg_param, $fixed_param, undef, $formatter_properties) = @$def;
	    $abort->("unknown command '$cmd'") if !$class;

	    $str .= $indent;
	    $str .= $class->usage_str($name, $prefix, $arg_param, $fixed_param, $format, $param_cb, $formatter_properties);
	}
	return $str;
    };

    return $generate->($indent, $separator, $def, $cmdstr);
}

__PACKAGE__->register_method ({
    name => 'help',
    path => 'help',
    method => 'GET',
    description => "Get help about specified command.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    'extra-args' => PVE::JSONSchema::get_standard_option('extra-args', {
		description => 'Shows help for a specific command',
		completion => $complete_command_names,
	    }),
	    verbose => {
		description => "Verbose output format.",
		type => 'boolean',
		optional => 1,
	    },
	},
    },
    returns => { type => 'null' },

    code => sub {
	my ($param) = @_;

	$assert_initialized->();

	my $cmd = $param->{'extra-args'};

	my $verbose = defined($cmd) && $cmd;
	$verbose = $param->{verbose} if defined($param->{verbose});

	if (!$cmd) {
	    if ($verbose) {
		print_usage_verbose();
	    } else {
		print_usage_short(\*STDOUT);
	    }
	    return undef;
	}

	my $str;
	if ($verbose) {
	    $str = generate_usage_str('full', $cmd, '');
	} else {
	    $str = generate_usage_str('short', $cmd, ' ' x 7);
	}
	$str =~ s/^\s+//;

	if ($verbose) {
	    print "$str\n";
	} else {
	    print "USAGE: $str\n";
	}

	return undef;

    }});

sub print_simple_asciidoc_synopsis {
    $assert_initialized->();

    my $synopsis = "*${exename}* `help`\n\n";
    $synopsis .= generate_usage_str('asciidoc');

    return $synopsis;
}

sub print_asciidoc_synopsis {
    $assert_initialized->();

    my $synopsis = "";

    $synopsis .= "*${exename}* `<COMMAND> [ARGS] [OPTIONS]`\n\n";

    $synopsis .= generate_usage_str('asciidoc');

    $synopsis .= "\n";

    return $synopsis;
}

sub print_usage_verbose {
    $assert_initialized->();

    print "USAGE: $exename <COMMAND> [ARGS] [OPTIONS]\n\n";

    my $str = generate_usage_str('full');

    print "$str\n";
}

sub print_usage_short {
    my ($fd, $msg, $cmd) = @_;

    $assert_initialized->();

    print $fd "ERROR: $msg\n" if $msg;
    print $fd "USAGE: $exename <COMMAND> [ARGS] [OPTIONS]\n";

    print {$fd} generate_usage_str('short', $cmd, ' ' x 7, "\n", sub {
	my ($h) = @_;
	return sort {
	    if (ref($h->{$a}) eq 'ARRAY' && ref($h->{$b}) eq 'ARRAY') {
		# $a and $b are both real commands order them by their class
		return $h->{$a}->[0] cmp $h->{$b}->[0] || $a cmp $b;
	    } elsif (ref($h->{$a}) eq 'ARRAY' xor ref($h->{$b}) eq 'ARRAY') {
		# real command and subcommand mixed, put sub commands first
		return ref($h->{$b}) eq 'ARRAY' ? -1 : 1;
	    } else {
		# both are either from the same class or subcommands
		return $a cmp $b;
	    }
	} keys %$h;
    });
}

my $print_bash_completion = sub {
    my ($simple_cmd, $bash_command, $cur, $prev) = @_;

    my $debug = 0;

    return if !(defined($cur) && defined($prev) && defined($bash_command));
    return if !defined($ENV{COMP_LINE});
    return if !defined($ENV{COMP_POINT});

    my $cmdline = substr($ENV{COMP_LINE}, 0, $ENV{COMP_POINT});
    print STDERR "\nCMDLINE: $ENV{COMP_LINE}\n" if $debug;

    my $args = PVE::Tools::split_args($cmdline);
    shift @$args; # no need for program name
    my $print_result = sub {
	foreach my $p (@_) {
	    print "$p\n" if $p =~ m/^\Q$cur\E/;
	}
    };

    my ($cmd, $def) = ($simple_cmd, $cmddef);
    if (!$simple_cmd) {
	($cmd, $def, $args, my $expanded) = resolve_cmd($args);

	if (defined($expanded) && $prev ne $expanded) {
	    print "$expanded\n";
	    return;
	}

	if (ref($def) eq 'HASH') {
	    &$print_result(@{$get_commands->($def)});
	    return;
	}
    }
    return if !$def;

    my $pos = scalar(@$args) - 1;
    $pos += 1 if $cmdline =~ m/\s+$/;
    print STDERR "pos: $pos\n" if $debug;
    return if $pos < 0;

    my $skip_param = {};

    my ($class, $name, $arg_param, $uri_param, undef, $formatter_properties) = @$def;
    $arg_param //= [];
    $uri_param //= {};

    $arg_param = [ $arg_param ] if !ref($arg_param);

    map { $skip_param->{$_} = 1; } @$arg_param;
    map { $skip_param->{$_} = 1; } keys %$uri_param;

    my $info = $class->map_method_by_name($name);

    my $prop = { %{$info->{parameters}->{properties}} }; # copy
    $prop = { %$prop, %$formatter_properties } if $formatter_properties;

    my $print_parameter_completion = sub {
	my ($pname) = @_;
	my $d = $prop->{$pname};
	if ($d->{completion}) {
	    my $vt = ref($d->{completion});
	    if ($vt eq 'CODE') {
		my $res = $d->{completion}->($cmd, $pname, $cur, $args);
		&$print_result(@$res);
	    }
	} elsif ($d->{type} eq 'boolean') {
	    &$print_result('0', '1');
	} elsif ($d->{enum}) {
	    &$print_result(@{$d->{enum}});
	}
    };

    # positional arguments
    if ($pos < scalar(@$arg_param)) {
	my $pname = $arg_param->[$pos];
	&$print_parameter_completion($pname);
	return;
    }

    my @option_list = ();
    foreach my $key (keys %$prop) {
	next if $skip_param->{$key};
	push @option_list, "--$key";
    }

    if ($cur =~ m/^-/) {
	&$print_result(@option_list);
	return;
    }

    if ($prev =~ m/^--?(.+)$/ && $prop->{$1}) {
	my $pname = $1;
	&$print_parameter_completion($pname);
	return;
    }

    &$print_result(@option_list);
};

sub verify_api {
    my ($class) = @_;

    # simply verify all registered methods
    PVE::RESTHandler::validate_method_schemas();
}

my $get_exe_name = sub {
    my ($class) = @_;

    my $name = $class;
    $name =~ s/^.*:://;
    $name =~ s/_/-/g;

    return $name;
};

sub generate_bash_completions {
    my ($class) = @_;

    # generate bash completion config

    $exename = &$get_exe_name($class);

    print <<__EOD__;
# $exename bash completion

# see http://tiswww.case.edu/php/chet/bash/FAQ
# and __ltrim_colon_completions() in /usr/share/bash-completion/bash_completion
# this modifies global var, but I found no better way
COMP_WORDBREAKS=\${COMP_WORDBREAKS//:}

complete -o default -C '$exename bashcomplete' $exename
__EOD__
}

sub generate_asciidoc_synopsys {
    my ($class) = @_;
    $class->generate_asciidoc_synopsis();
};

sub generate_asciidoc_synopsis {
    my ($class) = @_;

    $cli_handler_class = $class;

    $exename = &$get_exe_name($class);

    no strict 'refs';
    my $def = ${"${class}::cmddef"};
    $cmddef = $def;

    if (ref($def) eq 'ARRAY') {
	print_simple_asciidoc_synopsis();
    } else {
	$cmddef->{help} = [ __PACKAGE__, 'help', ['cmd'] ];

	print_asciidoc_synopsis();
    }
}

# overwrite this if you want to run/setup things early
sub setup_environment {
    my ($class) = @_;

    # do nothing by default
}

my $handle_cmd  = sub {
    my ($args, $preparefunc, $param_cb) = @_;

    $cmddef->{help} = [ __PACKAGE__, 'help', ['extra-args'] ];

    my ($cmd, $def, $cmd_args, undef, $cmd_str) = resolve_cmd($args);

    $abort->("no command specified") if !$cmd;

    # call verifyapi before setup_environment(), don't execute any real code in
    # this case
    if ($cmd eq 'verifyapi') {
	PVE::RESTHandler::validate_method_schemas();
	return;
    }

    $cli_handler_class->setup_environment();

    if ($cmd eq 'bashcomplete') {
	&$print_bash_completion(undef, @$cmd_args);
	return;
    }

    # checked special commands, if def is still a hash we got an incomplete sub command
    $abort->("incomplete command '$cmd_str'", $args) if ref($def) eq 'HASH';

    &$preparefunc() if $preparefunc;

    my ($class, $name, $arg_param, $uri_param, $outsub, $formatter_properties) = @{$def || []};
    $abort->("unknown command '$cmd_str'") if !$class;

    my ($res, $formatter_params) = $class->cli_handler(
	$cmd_str, $name, $cmd_args, $arg_param, $uri_param, $param_cb, $formatter_properties);

    if (defined $outsub) {
	my $result_schema = $class->map_method_by_name($name)->{returns};
	$outsub->($res, $result_schema, $formatter_params);
    }
};

my $handle_simple_cmd = sub {
    my ($args, $preparefunc, $param_cb) = @_;

    my ($class, $name, $arg_param, $uri_param, $outsub, $formatter_properties) = @{$cmddef};
    die "no class specified" if !$class;

    if (scalar(@$args) >= 1) {
	if ($args->[0] eq 'help') {
	    my $str = "USAGE: $name help\n";
	    $str .= generate_usage_str('long');
	    print STDERR "$str\n\n";
	    return;
	} elsif ($args->[0] eq 'verifyapi') {
	    PVE::RESTHandler::validate_method_schemas();
	    return;
	}
    }

    $cli_handler_class->setup_environment();

    if (scalar(@$args) >= 1) {
	if ($args->[0] eq 'bashcomplete') {
	    shift @$args;
	    &$print_bash_completion($name, @$args);
	    return;
	}
    }

    &$preparefunc() if $preparefunc;

    my ($res, $formatter_params) = $class->cli_handler(
	$name, $name, \@ARGV, $arg_param, $uri_param, $param_cb, $formatter_properties);

    if (defined $outsub) {
	my $result_schema = $class->map_method_by_name($name)->{returns};
	$outsub->($res, $result_schema, $formatter_params);
    }
};

sub run_cli_handler {
    my ($class, %params) = @_;

    $cli_handler_class = $class;

    $ENV{'PATH'} = '/sbin:/bin:/usr/sbin:/usr/bin';

    foreach my $key (keys %params) {
	next if $key eq 'prepare';
	next if $key eq 'no_init'; # not used anymore
	next if $key eq 'no_rpcenv'; # not used anymore
	die "unknown parameter '$key'";
    }

    my $preparefunc = $params{prepare};

    my $param_cb = $gen_param_mapping_func->($cli_handler_class);

    $exename = &$get_exe_name($class);

    my $logid = $ENV{PVE_LOG_ID} || $exename;
    initlog($logid);

    no strict 'refs';
    $cmddef = ${"${class}::cmddef"};

    if (ref($cmddef) eq 'ARRAY') {
	$handle_simple_cmd->(\@ARGV, $preparefunc, $param_cb);
    } else {
	$handle_cmd->(\@ARGV, $preparefunc, $param_cb);
    }

    exit 0;
}

1;
