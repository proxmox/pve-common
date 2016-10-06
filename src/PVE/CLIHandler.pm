package PVE::CLIHandler;

use strict;
use warnings;
use Data::Dumper;

use PVE::SafeSyslog;
use PVE::Exception qw(raise raise_param_exc);
use PVE::RESTHandler;
use PVE::INotify;

use base qw(PVE::RESTHandler);

my $cmddef;
my $exename;
my $cli_handler_class;

my $expand_command_name = sub {
    my ($def, $cmd) = @_;

    if (!$def->{$cmd}) {
	my $expanded;
	for my $k (keys(%$def)) {
	    if ($k =~ m/^$cmd/) {
		if ($expanded) {
		    $expanded = undef; # more than one match
		    last;
		} else {
		    $expanded = $k;
		}
	    }
	}
	$cmd = $expanded if $expanded;
    }
    return $cmd;
};

my $complete_command_names = sub {
    my $res = [];

    return if ref($cmddef) ne 'HASH';

    foreach my $cmd (keys %$cmddef) {
	next if $cmd eq 'help';
	push @$res, $cmd;
    }

    return $res;
};

__PACKAGE__->register_method ({
    name => 'help', 
    path => 'help',
    method => 'GET',
    description => "Get help about specified command.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    cmd => {
		description => "Command name",
		type => 'string',
		optional => 1,
		completion => $complete_command_names,
	    },
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

	die "not initialized" if !($cmddef && $exename && $cli_handler_class);

	my $cmd = $param->{cmd};

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

	$cmd = &$expand_command_name($cmddef, $cmd);

	my ($class, $name, $arg_param, $uri_param) = @{$cmddef->{$cmd} || []};

	raise_param_exc({ cmd => "no such command '$cmd'"}) if !$class;

	my $pwcallback = $cli_handler_class->can('read_password');
	my $stringfilemap = $cli_handler_class->can('string_param_file_mapping');

	my $str = $class->usage_str($name, "$exename $cmd", $arg_param, $uri_param,
				    $verbose ? 'full' : 'short', $pwcallback,
				    $stringfilemap);
	if ($verbose) {
	    print "$str\n";
	} else {
	    print "USAGE: $str\n";
	}

	return undef;

    }});

sub print_simple_asciidoc_synopsis {
    my ($class, $name, $arg_param, $uri_param) = @_;

    die "not initialized" if !$cli_handler_class;

    my $pwcallback = $cli_handler_class->can('read_password');
    my $stringfilemap = $cli_handler_class->can('string_param_file_mapping');

    my $synopsis = "*${name}* `help`\n\n";

    $synopsis .= $class->usage_str($name, $name, $arg_param, $uri_param,
				   'asciidoc', $pwcallback, $stringfilemap);

    return $synopsis;
}

sub print_asciidoc_synopsis {

    die "not initialized" if !($cmddef && $exename && $cli_handler_class);

    my $pwcallback = $cli_handler_class->can('read_password');
    my $stringfilemap = $cli_handler_class->can('string_param_file_mapping');

    my $synopsis = "";

    $synopsis .= "*${exename}* `<COMMAND> [ARGS] [OPTIONS]`\n\n";

    my $oldclass;
    foreach my $cmd (sort keys %$cmddef) {
	my ($class, $name, $arg_param, $uri_param) = @{$cmddef->{$cmd}};
	my $str = $class->usage_str($name, "$exename $cmd", $arg_param,
				    $uri_param, 'asciidoc', $pwcallback,
				    $stringfilemap);
	$synopsis .= "\n" if $oldclass && $oldclass ne $class;

	$synopsis .= "$str\n\n";
	$oldclass = $class;
    }

    $synopsis .= "\n";

    return $synopsis;
}

sub print_usage_verbose {

    die "not initialized" if !($cmddef && $exename && $cli_handler_class);

    my $pwcallback = $cli_handler_class->can('read_password');
    my $stringfilemap = $cli_handler_class->can('string_param_file_mapping');

    print "USAGE: $exename <COMMAND> [ARGS] [OPTIONS]\n\n";

    foreach my $cmd (sort keys %$cmddef) {
	my ($class, $name, $arg_param, $uri_param) = @{$cmddef->{$cmd}};
	my $str = $class->usage_str($name, "$exename $cmd", $arg_param, $uri_param,
				    'full', $pwcallback, $stringfilemap);
	print "$str\n\n";
    }
}

sub sorted_commands {   
    return sort { ($cmddef->{$a}->[0] cmp $cmddef->{$b}->[0]) || ($a cmp $b)} keys %$cmddef;
}

sub print_usage_short {
    my ($fd, $msg) = @_;

    die "not initialized" if !($cmddef && $exename && $cli_handler_class);

    my $pwcallback = $cli_handler_class->can('read_password');
    my $stringfilemap = $cli_handler_class->can('string_param_file_mapping');

    print $fd "ERROR: $msg\n" if $msg;
    print $fd "USAGE: $exename <COMMAND> [ARGS] [OPTIONS]\n";

    my $oldclass;
    foreach my $cmd (sorted_commands()) {
	my ($class, $name, $arg_param, $uri_param) = @{$cmddef->{$cmd}};
	my $str = $class->usage_str($name, "$exename $cmd", $arg_param, $uri_param, 'short', $pwcallback, $stringfilemap);
	print $fd "\n" if $oldclass && $oldclass ne $class;
	print $fd "       $str";
	$oldclass = $class;
    }
}

my $print_bash_completion = sub {
    my ($cmddef, $simple_cmd, $bash_command, $cur, $prev) = @_;

    my $debug = 0;

    return if !(defined($cur) && defined($prev) && defined($bash_command));
    return if !defined($ENV{COMP_LINE});
    return if !defined($ENV{COMP_POINT});

    my $cmdline = substr($ENV{COMP_LINE}, 0, $ENV{COMP_POINT});
    print STDERR "\nCMDLINE: $ENV{COMP_LINE}\n" if $debug;

    my $args = PVE::Tools::split_args($cmdline);
    my $pos = scalar(@$args) - 2;
    $pos += 1 if $cmdline =~ m/\s+$/;

    print STDERR "CMDLINE:$pos:$cmdline\n" if $debug;

    return if $pos < 0;

    my $print_result = sub {
	foreach my $p (@_) {
	    print "$p\n" if $p =~ m/^$cur/;
	}
    };

    my $cmd;
    if ($simple_cmd) {
	$cmd = $simple_cmd;
    } else {
	if ($pos == 0) {
	    &$print_result(keys %$cmddef);
	    return;
	}
	$cmd = $args->[1];
    }

    my $def = $cmddef->{$cmd};
    return if !$def;

    print STDERR "CMDLINE1:$pos:$cmdline\n" if $debug;

    my $skip_param = {};

    my ($class, $name, $arg_param, $uri_param) = @$def;
    $arg_param //= [];
    $uri_param //= {};

    $arg_param = [ $arg_param ] if !ref($arg_param);

    map { $skip_param->{$_} = 1; } @$arg_param;
    map { $skip_param->{$_} = 1; } keys %$uri_param;

    my $fpcount = scalar(@$arg_param);

    my $info = $class->map_method_by_name($name);

    my $schema = $info->{parameters};
    my $prop = $schema->{properties};

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
    $pos += 1 if $simple_cmd;
    if ($fpcount && $pos <= $fpcount) {
	my $pname = $arg_param->[$pos -1];
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

sub find_cli_class_source {
    my ($name) = @_;

    my $filename;

    $name =~ s/-/_/g;

    my $cpath = "PVE/CLI/${name}.pm";
    my $spath = "PVE/Service/${name}.pm";
    foreach my $p (@INC) {
	foreach my $s (($cpath, $spath)) {
	    my $testfn = "$p/$s";
	    if (-f $testfn) {
		$filename = $testfn;
		last;
	    }
	}
	last if defined($filename);
    }

    return $filename;
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

    if (ref($def) eq 'ARRAY') {
	print_simple_asciidoc_synopsis(@$def);
    } else {
	$cmddef = $def;

	$cmddef->{help} = [ __PACKAGE__, 'help', ['cmd'] ];

	print_asciidoc_synopsis();
    }
}

my $handle_cmd  = sub {
    my ($def, $cmdname, $cmd, $args, $pwcallback, $preparefunc, $stringfilemap) = @_;

    $cmddef = $def;
    $exename = $cmdname;

    $cmddef->{help} = [ __PACKAGE__, 'help', ['cmd'] ];

    if (!$cmd) { 
	print_usage_short (\*STDERR, "no command specified");
	exit (-1);
    } elsif ($cmd eq 'verifyapi') {
	PVE::RESTHandler::validate_method_schemas();
	return;
    } elsif ($cmd eq 'bashcomplete') {
	&$print_bash_completion($cmddef, 0, @$args);
	return;
    }

    &$preparefunc() if $preparefunc;

    $cmd = &$expand_command_name($cmddef, $cmd);

    my ($class, $name, $arg_param, $uri_param, $outsub) = @{$cmddef->{$cmd} || []};

    if (!$class) {
	print_usage_short (\*STDERR, "unknown command '$cmd'");
	exit (-1);
    }

    my $prefix = "$exename $cmd";
    my $res = $class->cli_handler($prefix, $name, \@ARGV, $arg_param, $uri_param, $pwcallback, $stringfilemap);

    &$outsub($res) if $outsub;
};

my $handle_simple_cmd = sub {
    my ($def, $args, $pwcallback, $preparefunc, $stringfilemap) = @_;

    my ($class, $name, $arg_param, $uri_param, $outsub) = @{$def};
    die "no class specified" if !$class;

    if (scalar(@$args) >= 1) {
	if ($args->[0] eq 'help') {
	    my $str = "USAGE: $name help\n";
	    $str .= $class->usage_str($name, $name, $arg_param, $uri_param, 'long', $pwcallback, $stringfilemap);
	    print STDERR "$str\n\n";
	    return;
	} elsif ($args->[0] eq 'bashcomplete') {
	    shift @$args;
	    &$print_bash_completion({ $name => $def }, $name, @$args);
	    return;
	} elsif ($args->[0] eq 'verifyapi') {
	    PVE::RESTHandler::validate_method_schemas();
	    return;
	}
    }

    &$preparefunc() if $preparefunc;

    my $res = $class->cli_handler($name, $name, \@ARGV, $arg_param, $uri_param, $pwcallback, $stringfilemap);

    &$outsub($res) if $outsub;
};

sub run_cli {
    my ($class, $pwcallback, $podfn, $preparefunc) = @_;

    # Note: "depreciated function run_cli - use run_cli_handler instead";
    # silently ignore $podfn , which is no longer supported.

    die "password callback is no longer supported" if $pwcallback;

    run_cli_handler($class, prepare => $preparefunc);
}

sub run_cli_handler {
    my ($class, %params) = @_;

    $cli_handler_class = $class;

    $ENV{'PATH'} = '/sbin:/bin:/usr/sbin:/usr/bin';

    foreach my $key (keys %params) {
	next if $key eq 'prepare';
	next if $key eq 'no_init'; # used by lxc hooks
	next if $key eq 'no_rpcenv';
	die "unknown parameter '$key'";
    }

    my $preparefunc = $params{prepare};
    my $no_init = $params{no_init};
    my $no_rpcenv = $params{no_rpcenv};

    my $pwcallback = $class->can('read_password');
    my $stringfilemap = $class->can('string_param_file_mapping');

    $exename = &$get_exe_name($class);

    initlog($exename);

    if ($class !~ m/^PVE::Service::/) {
	die "please run as root\n" if $> != 0;

	PVE::INotify::inotify_init() if !$no_init;

	if (!$no_rpcenv) {
	my $rpcenv = PVE::RPCEnvironment->init('cli');
	    $rpcenv->init_request() if !$no_init;
	    $rpcenv->set_language($ENV{LANG});
	    $rpcenv->set_user('root@pam');
	}
    }

    no strict 'refs';
    my $def = ${"${class}::cmddef"};

    if (ref($def) eq 'ARRAY') {
	&$handle_simple_cmd($def, \@ARGV, $pwcallback, $preparefunc, $stringfilemap);
    } else {
	$cmddef = $def;
	my $cmd = shift @ARGV;
	&$handle_cmd($cmddef, $exename, $cmd, \@ARGV, $pwcallback, $preparefunc, $stringfilemap);
    }

    exit 0;
}

1;
