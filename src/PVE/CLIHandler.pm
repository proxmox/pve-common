package PVE::CLIHandler;

use strict;
use warnings;

use PVE::Exception qw(raise raise_param_exc);
use PVE::RESTHandler;
use PVE::PodParser;

use base qw(PVE::RESTHandler);

my $cmddef;
my $exename;

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

	die "not initialized" if !($cmddef && $exename);

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


	my $str = $class->usage_str($name, "$exename $cmd", $arg_param, $uri_param, $verbose ? 'full' : 'short');
	if ($verbose) {
	    print "$str\n";
	} else {
	    print "USAGE: $str\n";
	}

	return undef;

    }});

sub print_pod_manpage {
    my ($podfn) = @_;

    die "not initialized" if !($cmddef && $exename);
    die "no pod file specified" if !$podfn;

    my $synopsis = "";
    
    $synopsis .= " $exename <COMMAND> [ARGS] [OPTIONS]\n\n";

    my $style = 'full'; # or should we use 'short'?
    my $oldclass;
    foreach my $cmd (sorted_commands()) {
	my ($class, $name, $arg_param, $uri_param) = @{$cmddef->{$cmd}};
	my $str = $class->usage_str($name, "$exename $cmd", $arg_param, 
				    $uri_param, $style);
	$str =~ s/^USAGE: //;

	$synopsis .= "\n" if $oldclass && $oldclass ne $class;
	$str =~ s/\n/\n /g;
	$synopsis .= " $str\n\n";
	$oldclass = $class;
    }

    $synopsis .= "\n";

    my $parser = PVE::PodParser->new();
    $parser->{include}->{synopsis} = $synopsis;
    $parser->parse_from_file($podfn);
}

sub print_usage_verbose {

    die "not initialized" if !($cmddef && $exename);

    print "USAGE: $exename <COMMAND> [ARGS] [OPTIONS]\n\n";

    foreach my $cmd (sort keys %$cmddef) {
	my ($class, $name, $arg_param, $uri_param) = @{$cmddef->{$cmd}};
	my $str = $class->usage_str($name, "$exename $cmd", $arg_param, $uri_param, 'full');
	print "$str\n\n";
    }
}

sub sorted_commands {   
    return sort { ($cmddef->{$a}->[0] cmp $cmddef->{$b}->[0]) || ($a cmp $b)} keys %$cmddef;
}

sub print_usage_short {
    my ($fd, $msg) = @_;

    die "not initialized" if !($cmddef && $exename);

    print $fd "ERROR: $msg\n" if $msg;
    print $fd "USAGE: $exename <COMMAND> [ARGS] [OPTIONS]\n";

    my $oldclass;
    foreach my $cmd (sorted_commands()) {
	my ($class, $name, $arg_param, $uri_param) = @{$cmddef->{$cmd}};
	my $str = $class->usage_str($name, "$exename $cmd", $arg_param, $uri_param, 'short');
	print $fd "\n" if $oldclass && $oldclass ne $class;
	print $fd "       $str";
	$oldclass = $class;
    }
}

sub handle_cmd {
    my ($def, $cmdname, $cmd, $args, $pwcallback, $podfn, $preparefunc) = @_;

    $cmddef = $def;
    $exename = $cmdname;

    $cmddef->{help} = [ __PACKAGE__, 'help', ['cmd'] ];

    if (!$cmd) { 
	print_usage_short (\*STDERR, "no command specified");
	exit (-1);
    } elsif ($cmd eq 'verifyapi') {
	PVE::RESTHandler::validate_method_schemas();
	return;
    } elsif ($cmd eq 'printmanpod') {
	print_pod_manpage($podfn);
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
    my $res = $class->cli_handler($prefix, $name, \@ARGV, $arg_param, $uri_param, $pwcallback);

    &$outsub($res) if $outsub;
}

sub handle_simple_cmd {
    my ($def, $args, $pwcallback, $podfn) = @_;

    my ($class, $name, $arg_param, $uri_param, $outsub) = @{$def};
    die "no class specified" if !$class;

    if (scalar(@$args) == 1) {
	if ($args->[0] eq 'help') {
	    my $str = "USAGE: $name help\n";
	    $str .= $class->usage_str($name, $name, $arg_param, $uri_param, 'long');
	    print STDERR "$str\n\n";
	    return;
	} elsif ($args->[0] eq 'verifyapi') {
	    PVE::RESTHandler::validate_method_schemas();
	    return;
	} elsif ($args->[0] eq 'printmanpod') {
	    my $synopsis = " $name help\n\n";
	    my $str = $class->usage_str($name, $name, $arg_param, $uri_param, 'long');
	    $str =~ s/^USAGE://;
	    $str =~ s/\n/\n /g;
	    $synopsis .= $str;

	    my $parser = PVE::PodParser->new();
	    $parser->{include}->{synopsis} = $synopsis;
	    $parser->parse_from_file($podfn);
	    return;
	}
    }

    my $res = $class->cli_handler($name, $name, \@ARGV, $arg_param, $uri_param, $pwcallback);

    &$outsub($res) if $outsub;
}

1;
