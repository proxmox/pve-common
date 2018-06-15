package PVE::Systemd;

use strict;
use warnings;

use Net::DBus qw(dbus_uint32 dbus_uint64);
use Net::DBus::Callback;
use Net::DBus::Reactor;

# NOTE: This calls the dbus main loop and must not be used when another dbus
# main loop is being used as we need to wait for the JobRemoved signal.
# Polling the job status instead doesn't work because this doesn't give us the
# distinction between success and failure.
#
# Note that the description is mandatory for security reasons.
sub enter_systemd_scope {
    my ($unit, $description, %extra) = @_;
    die "missing description\n" if !defined($description);

    my $timeout = delete $extra{timeout};

    $unit .= '.scope';
    my $properties = [ [PIDs => [dbus_uint32($$)]] ];

    foreach my $key (keys %extra) {
	if ($key eq 'Slice' || $key eq 'KillMode') {
	    push @{$properties}, [$key, $extra{$key}];
	} elsif ($key eq 'CPUShares') {
	    push @{$properties}, [$key, dbus_uint64($extra{$key})];
	} elsif ($key eq 'CPUQuota') {
	    push @{$properties}, ['CPUQuotaPerSecUSec',
	                          dbus_uint64($extra{$key} * 10_000)];
	} else {
	    die "Don't know how to encode $key for systemd scope\n";
	}
    }

    my $job;
    my $done = 0;

    my $bus = Net::DBus->system();
    my $reactor = Net::DBus::Reactor->main();

    my $service = $bus->get_service('org.freedesktop.systemd1');
    my $if = $service->get_object('/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager');
    # Connect to the JobRemoved signal since we want to wait for it to finish
    my $sigid;
    my $timer;
    my $cleanup = sub {
	my ($no_shutdown) = @_;
	$if->disconnect_from_signal('JobRemoved', $sigid) if defined($if);
	$if = undef;
	$sigid = undef;
	$reactor->remove_timeout($timer) if defined($timer);
	$timer = undef;
	return if $no_shutdown;
	$reactor->shutdown();
    };

    $sigid = $if->connect_to_signal('JobRemoved', sub {
	my ($id, $removed_job, $signaled_unit, $result) = @_;
	return if $signaled_unit ne $unit || $removed_job ne $job;
	$cleanup->(0);
	die "systemd job failed\n" if $result ne 'done';
	$done = 1;
    });

    my $on_timeout = sub {
	$cleanup->(0);
	die "systemd job timed out\n";
    };

    $timer = $reactor->add_timeout($timeout * 1000, Net::DBus::Callback->new(method => $on_timeout))
	if defined($timeout);
    $job = $if->StartTransientUnit($unit, 'fail', $properties, []);
    $reactor->run();
    $cleanup->(1);
    die "systemd job never completed\n" if !$done;
}

1;
