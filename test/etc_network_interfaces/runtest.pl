#!/usr/bin/perl

use lib '../../src';
use lib '.';
use strict;
use warnings;

use Carp;
use POSIX;
use IO::Handle;
use Storable qw(dclone);
use JSON; # allows simple debug-dumping of variables  `print to_json($foo, {pretty => 1}) ."\n"`

use PVE::INotify;

# Current config, r() parses a network interface string into this variable
our $config;

##
## Temporary files:
##
# perl conveniently lets you open a string as filehandle so we allow tests
# to temporarily save interface files to virtual files:
my %saved_files;

# Load a temp-file and return it as a string, if it didn't exist, try loading
# a real file.
sub load($) {
    my ($from) = @_;

    if (my $local = $saved_files{$from}) {
      return $local;
    }

    open my $fh, '<', $from or die "failed to open $from: $!";
    local $/ = undef;
    my $data = <$fh>;
    close $fh;
    return $data;
}

# Save a temporary file.
sub save($$) {
    my ($file, $data) = @_;
    $saved_files{$file} = $data;
}

# Delete a temporary file
sub delfile($) {
    my $file = @_;
    die "no such file: $file" if !delete $saved_files{$file};
}

# Delete all temporary files.
sub flush_files() {
    foreach (keys %saved_files) {
	delete $saved_files{$_} if $_ !~ m,^shared/,;
    }
}

##
## Interface parsing:
##

# Read an interfaces file with optional /proc/net/dev file content string and
# the list of active interfaces, which otherwise default
sub r($;$$) {
    my ($ifaces, $proc_net_dev, $active) = @_;
    $proc_net_dev //= load('proc_net_dev');
    $active //= [split(/\s+/, load('active_interfaces'))];
    open my $fh1, '<', \$ifaces;
    open my $fh2, '<', \$proc_net_dev;
    $config = PVE::INotify::__read_etc_network_interfaces($fh1, $fh2, $active);
    close $fh1;
}

# Turn the current network config into a string.
sub w() {
    # write shouldn't be able to change a previously parsed config
    my $config_clone = dclone($config);
    return PVE::INotify::__write_etc_network_interfaces($config_clone, 1);
}

##
## Interface modification helpers
##

# Update an interface
sub update_iface($$%) {
    my ($name, $families, %extra) = @_;

    my $ifaces = $config->{ifaces};
    my $if = $ifaces->{$name};

    die "no such interface: $name\n" if !$if;

    $if->{exists} = 1;

    # merge extra flags (like bridge_ports, ovs_*) directly
    $if->{$_} = $extra{$_} foreach keys %extra;

    return if !$families;

    my $if_families = $if->{families} ||= [];
    foreach my $family (@$families) {
	my $type = delete $family->{family};
	@$if_families = ((grep { $_ ne $type } @$if_families), $type);

	(my $suffix = $type) =~ s/^inet//;
	$if->{"method$suffix"} = $family->{address} ? 'static' : 'manual';
	foreach(qw(address netmask gateway options)) {
	    if (my $value = delete $family->{$_}) {
		$if->{"$_${suffix}"} = $value;
	    }
	}
    }
}

# Create an interface and error if it already exists.
sub new_iface($$$%) {
    my ($name, $type, $families, %extra) = @_;
    my $ifaces = $config->{ifaces};
    croak "interface already exists: $name" if $ifaces->{$name};
    $ifaces->{$name} = { type => $type };
    update_iface($name, $families, %extra);
}

# Delete an interface and error if it did not exist.
sub delete_iface($;$) {
    my ($name, $family) = @_;
    my $ifaces = $config->{ifaces};
    my $if = $ifaces->{$name} ||= {};
    croak "interface doesn't exist: $name" if !$if;

    if (!$family) {
      delete $ifaces->{$name};
      return;
    }

    my $families = $if->{families};
    @$families = grep {$_ ne $family} @$families;
    (my $suffix = $family) =~ s/^inet//;
    delete $if->{"$_$suffix"} foreach qw(address netmask gateway options);
}

##
## Test helpers:
##

# Compare two strings line by line and show a diff/error if they differ.
sub diff($$) {
    my ($a, $b) = @_;
    return if $a eq $b;

    my ($ra, $wa) = POSIX::pipe();
    my ($rb, $wb) = POSIX::pipe();
    my $ha = IO::Handle->new_from_fd($wa, 'w');
    my $hb = IO::Handle->new_from_fd($wb, 'w');

    open my $diffproc, '-|', 'diff', '-up', "/dev/fd/$ra", "/dev/fd/$rb"
	or die "failed to run program 'diff': $!";
    POSIX::close($ra);
    POSIX::close($rb);

    open my $f1, '<', \$a;
    open my $f2, '<', \$b;
    my ($line1, $line2);
    do {
	$ha->print($line1) if defined($line1 = <$f1>);
	$hb->print($line2) if defined($line2 = <$f2>);
    } while (defined($line1 // $line2));
    close $f1;
    close $f2;
    close $ha;
    close $hb;

    local $/ = undef;
    my $diff = <$diffproc>;
    close $diffproc;
    die "files differ:\n$diff";
}

# Write the current interface config and compare the result to a string.
sub expect($) {
    my ($expected) = @_;
    my $got = w();
    diff($expected, $got);
}

##
## Main test execution:
##
# (sorted, it's not used right now but tests could pass on temporary files by
# prefixing the name with shared/ and thus you might want to split a larger
# test into t.01.first-part.pl, t.02.second-part.pl, etc.
my $total = 0;
my $failed = 0;
for our $Test (sort <t.*.pl>) {
    $total++;
    flush_files();
    eval {
	require $Test;
    };
    if ($@) {
	print "FAIL: $Test\n$@\n\n";
	$failed++;
    } else {
	print "PASS: $Test\n";
    }
}

die "$failed out of $total tests failed\n" if $failed;
