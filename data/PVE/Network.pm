package PVE::Network;

use strict;
use PVE::Tools qw(run_command);
use PVE::ProcFSTools;
use PVE::INotify;
use File::Basename;

# host network related utility functions

sub setup_tc_rate_limit {
    my ($iface, $rate, $burst, $debug) = @_;

    system("/sbin/tc qdisc del dev $iface ingres >/dev/null 2>&1");
    system("/sbin/tc qdisc del dev $iface root >/dev/null 2>&1");

    run_command("/sbin/tc qdisc add dev $iface handle ffff: ingress");

    # this does not work wit virtio - don't know why (setting "mtu 64kb" does not help)
    #run_command("/sbin/tc filter add dev $iface parent ffff: protocol ip prio 50 u32 match ip src 0.0.0.0/0 police rate ${rate}bps burst ${burst}b drop flowid :1");
    # so we use avrate instead
    run_command("/sbin/tc filter add dev $iface parent ffff: " .
		"protocol ip prio 50 estimator 1sec 8sec " .
		"u32 match ip src 0.0.0.0/0 police avrate ${rate}bps drop flowid :1");

    # tbf does not work for unknown reason
    #$TC qdisc add dev $DEV root tbf rate $RATE latency 100ms burst $BURST
    # so we use htb instead
    run_command("/sbin/tc qdisc add dev $iface root handle 1: htb default 1");
    run_command("/sbin/tc class add dev $iface parent 1: classid 1:1 " .
		"htb rate ${rate}bps burst ${burst}b");

    if ($debug) {
	print "DEBUG tc settings\n";
	system("/sbin/tc qdisc ls dev $iface");
	system("/sbin/tc class ls dev $iface");
	system("/sbin/tc filter ls dev $iface parent ffff:");
    }
}


sub copy_bridge_config {
    my ($br0, $br1) = @_;

    return if $br0 eq $br1;

    my $br_configs = [ 'ageing_time', 'stp_state', 'priority', 'forward_delay', 
		       'hello_time', 'max_age', 'multicast_snooping', 'multicast_querier'];

    foreach my $sysname (@$br_configs) {
	eval {
	    my $v0 = PVE::Tools::file_read_firstline("/sys/class/net/$br0/bridge/$sysname");
	    my $v1 = PVE::Tools::file_read_firstline("/sys/class/net/$br1/bridge/$sysname");
	    if ($v0 ne $v1) {
		system("echo \"$v0\" > /sys/class/net/$br1/bridge/$sysname") == 0 ||
		    warn "unable to set bridge config '$sysname'\n";
	    }
	};
	warn $@ if $@;
    }
}

sub activate_bridge_vlan {
    my ($bridge, $tag_param) = @_;

    die "bridge '$bridge' is not active\n" if ! -d "/sys/class/net/$bridge";

    return $bridge if !defined($tag_param); # no vlan, simply return

    my $tag = int($tag_param);

    die "got strange vlan tag '$tag_param'\n" if $tag < 1 || $tag > 4094;

    my $bridgevlan = "${bridge}v$tag";

    my $dir = "/sys/class/net/$bridge/brif";

    #check if we have an only one ethX or bondX interface in the bridge
    
    my $iface;
    PVE::Tools::dir_glob_foreach($dir, '((eth|bond)\d+)', sub {
	my ($slave) = @_;

	die "more then one physical interfaces on bridge '$bridge'\n" if $iface;
	$iface = $slave;

    });

    die "no physical interface on bridge '$bridge'\n" if !$iface;

    my $ifacevlan = "${iface}.$tag";

    # create vlan on $iface is not already exist
    if (! -d "/sys/class/net/$ifacevlan") {
	system("/sbin/vconfig add $iface $tag") == 0 ||
	    die "can't add vlan tag $tag to interface $iface\n";
    }

    # be sure to have the $ifacevlan up
    system("/sbin/ip link set $ifacevlan up") == 0 ||
        die "can't up interface $ifacevlan\n";

    # test if $vlaniface is already enslaved in another bridge
    my $path= "/sys/class/net/$ifacevlan/brport/bridge";
    if (-l $path) {
        my $tbridge = basename(readlink($path));
	if ($tbridge eq $bridgevlan) {
	    # already member of bridge - assume setup is already done
	    return $bridgevlan;
	} else {
	    die "interface $ifacevlan already exist in bridge $tbridge\n";
	}
    }

    # add bridgevlan if it doesn't already exist
    if (! -d "/sys/class/net/$bridgevlan") {
        system("/usr/sbin/brctl addbr $bridgevlan") == 0 ||
            die "can't add bridge $bridgevlan\n";
    }

    #fixme: set other bridge flags

    # be sure to have the bridge up
    system("/sbin/ip link set $bridgevlan up") == 0 ||
        die "can't up bridge $bridgevlan\n";

    # add $ifacevlan to the bridge
    system("/usr/sbin/brctl addif $bridgevlan $ifacevlan") == 0 ||
	die "can't add interface $ifacevlan to bridge $bridgevlan\n";
    
    return $bridgevlan;
}

1;
