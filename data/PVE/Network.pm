package PVE::Network;

use strict;
use warnings;
use PVE::Tools qw(run_command);
use PVE::ProcFSTools;
use PVE::INotify;
use File::Basename;

# host network related utility functions

sub setup_tc_rate_limit {
    my ($iface, $rate, $burst, $debug) = @_;

    system("/sbin/tc class del dev $iface parent 1: classid 1:1 >/dev/null 2>&1");
    system("/sbin/tc filter del dev $iface parent ffff: protocol ip prio 50 estimator 1sec 8sec >/dev/null 2>&1");
    system("/sbin/tc qdisc del dev $iface ingress >/dev/null 2>&1");
    system("/sbin/tc qdisc del dev $iface root >/dev/null 2>&1");

    return if !$rate;

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

sub tap_rate_limit {
    my ($iface, $rate) = @_;

    my $debug = 0;
    $rate = int($rate*1024*1024);
    my $burst = 1024*1024;

    setup_tc_rate_limit($iface, $rate, $burst, $debug);
}

my $read_bridge_mtu = sub {
    my ($bridge) = @_;

    my $mtu = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/mtu");
    die "bridge '$bridge' does not exist\n" if !$mtu;
    # avoid insecure dependency;
    die "unable to parse mtu value" if $mtu !~ /^(\d+)$/;
    $mtu = int($1);

    return $mtu;
};

my $parse_tap_devive_name = sub {
    my ($iface, $noerr) = @_;

    my ($vmid, $devid);

    if ($iface =~ m/^tap(\d+)i(\d+)$/) {
	$vmid = $1;
	$devid = $2;
    } elsif ($iface =~ m/^veth(\d+)\.(\d+)$/) {
	$vmid = $1;
	$devid = $2;
    } else {
	return undef if $noerr;
	die "can't create firewall bridge for random interface name '$iface'\n";
    }

    return ($vmid, $devid);
};

my $compute_fwbr_names = sub {
    my ($vmid, $devid) = @_;

    my $fwbr = "fwbr${vmid}i${devid}";
    # Note: the firewall use 'fwln+' to filter traffic to VMs
    my $vethfw = "fwln${vmid}i${devid}";
    my $vethfwpeer = "fwpr${vmid}p${devid}";
    my $ovsintport = "fwln${vmid}o${devid}";

    return ($fwbr, $vethfw, $vethfwpeer, $ovsintport);
};

my $cond_create_bridge = sub {
    my ($bridge) = @_;

    if (! -d "/sys/class/net/$bridge") {
        system("/sbin/brctl addbr $bridge") == 0 ||
            die "can't add bridge '$bridge'\n";
    }
};

my $bridge_add_interface = sub {
    my ($bridge, $iface) = @_;

    system("/sbin/brctl addif $bridge $iface") == 0 ||
	die "can't add interface 'iface' to bridge '$bridge'\n";
};

my $ovs_bridge_add_port = sub {
    my ($bridge, $iface, $tag, $internal) = @_;

    my $cmd = "/usr/bin/ovs-vsctl add-port $bridge $iface";
    $cmd .= " tag=$tag" if $tag;
    $cmd .= " -- set Interface $iface type=internal" if $internal;
    system($cmd) == 0 ||
	die "can't add ovs port '$iface'\n";
};

my $activate_interface = sub {
    my ($iface) = @_;

    system("/sbin/ip link set $iface up") == 0 ||
	die "can't activate interface '$iface'\n";
};

sub tap_create {
    my ($iface, $bridge) = @_;

    die "unable to get bridge setting\n" if !$bridge;

    my $bridgemtu = &$read_bridge_mtu($bridge);

    eval { 
	PVE::Tools::run_command("/sbin/ifconfig $iface 0.0.0.0 promisc up mtu $bridgemtu");
    };
    die "interface activation failed\n" if $@;
}

my $create_firewall_bridge_linux = sub {
    my ($iface, $bridge) = @_;

    my ($vmid, $devid) = &$parse_tap_devive_name($iface);
    my ($fwbr, $vethfw, $vethfwpeer) = &$compute_fwbr_names($vmid, $devid);

    my $bridgemtu = &$read_bridge_mtu($bridge);

    &$cond_create_bridge($fwbr);
    &$activate_interface($fwbr);

    copy_bridge_config($bridge, $fwbr);
    # create veth pair
    if (! -d "/sys/class/net/$vethfw") {
	system("/sbin/ip link add name $vethfw type veth peer name $vethfwpeer mtu $bridgemtu") == 0 ||
	    die "can't create interface $vethfw\n";
    }

    # up vethpair
    &$activate_interface($vethfw);
    &$activate_interface($vethfwpeer);

    &$bridge_add_interface($fwbr, $vethfw);
    &$bridge_add_interface($bridge, $vethfwpeer);

    return $fwbr;
};

my $create_firewall_bridge_ovs = sub {
    my ($iface, $bridge, $tag) = @_;

    my ($vmid, $devid) = &$parse_tap_devive_name($iface);
    my ($fwbr, undef, undef, $ovsintport) = &$compute_fwbr_names($vmid, $devid);

    my $bridgemtu = &$read_bridge_mtu($bridge);

    &$cond_create_bridge($fwbr);
    &$activate_interface($fwbr);

    &$bridge_add_interface($fwbr, $iface);

    &$ovs_bridge_add_port($bridge, $ovsintport, $tag, 1);
    &$activate_interface($ovsintport);

    # set the same mtu for ovs int port
    PVE::Tools::run_command("/sbin/ifconfig $ovsintport mtu $bridgemtu");
    
    &$bridge_add_interface($fwbr, $ovsintport);
};

my $cleanup_firewall_bridge = sub {
    my ($iface) = @_;

    my ($vmid, $devid) = &$parse_tap_devive_name($iface, 1);
    return if !defined($vmid);  
    my ($fwbr, $vethfw, $vethfwpeer, $ovsintport) = &$compute_fwbr_names($vmid, $devid);

    # cleanup old port config from any openvswitch bridge
    if (-d "/sys/class/net/$ovsintport") {
	run_command("/usr/bin/ovs-vsctl del-port $ovsintport", outfunc => sub {}, errfunc => sub {});
    }

    # delete old vethfw interface
    if (-d "/sys/class/net/$vethfw") {
	run_command("/sbin/ip link delete dev $vethfw", outfunc => sub {}, errfunc => sub {});
    }

    # cleanup fwbr bridge
    if (-d "/sys/class/net/$fwbr") {
	run_command("/sbin/ip link set dev $fwbr down", outfunc => sub {}, errfunc => sub {});
	run_command("/sbin/brctl delbr $fwbr", outfunc => sub {}, errfunc => sub {});
    }
};

sub tap_plug {
    my ($iface, $bridge, $tag, $firewall) = @_;

    #cleanup old port config from any openvswitch bridge
    eval {run_command("/usr/bin/ovs-vsctl del-port $iface", outfunc => sub {}, errfunc => sub {}) };

    if (-d "/sys/class/net/$bridge/bridge") {
	&$cleanup_firewall_bridge($iface); # remove stale devices

	my $newbridge = activate_bridge_vlan($bridge, $tag);
	copy_bridge_config($bridge, $newbridge) if $bridge ne $newbridge;

	$newbridge = &$create_firewall_bridge_linux($iface, $newbridge) if $firewall;

	&$bridge_add_interface($newbridge, $iface);
    } else {
	&$cleanup_firewall_bridge($iface); # remove stale devices

	if ($firewall) {
	    &$create_firewall_bridge_ovs($iface, $bridge, $tag);
	} else {
	    &$ovs_bridge_add_port($bridge, $iface, $tag);
	}
    }
}

sub tap_unplug {
    my ($iface) = @_;

    my $path= "/sys/class/net/$iface/brport/bridge";
    if (-l $path) {
	my $bridge = basename(readlink($path));
	#avoid insecure dependency;
	($bridge) = $bridge =~ /(\S+)/;

	system("/sbin/brctl delif $bridge $iface") == 0 ||
	    die "can't del interface '$iface' from bridge '$bridge'\n";

    }
    
    &$cleanup_firewall_bridge($iface);
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
		 PVE::ProcFSTools::write_proc_entry("/sys/class/net/$br1/bridge/$sysname", $v0);
	    }
	};
	warn $@ if $@;
    }
}

sub activate_bridge_vlan_slave {
    my ($bridgevlan, $iface, $tag) = @_;
    my $ifacevlan = "${iface}.$tag";
	
    # create vlan on $iface is not already exist
    if (! -d "/sys/class/net/$ifacevlan") {
	system("/sbin/vconfig add $iface $tag") == 0 ||
	    die "can't add vlan tag $tag to interface $iface\n";
    }

    # be sure to have the $ifacevlan up
    &$activate_interface($ifacevlan);

    # test if $vlaniface is already enslaved in another bridge
    my $path= "/sys/class/net/$ifacevlan/brport/bridge";
    if (-l $path) {
        my $tbridge = basename(readlink($path));
	if ($tbridge ne $bridgevlan) {
	    die "interface $ifacevlan already exist in bridge $tbridge\n";
	} else {
            # Port already attached to bridge: do nothing.
            return;
	}
    }

    # add $ifacevlan to the bridge
    &$bridge_add_interface($bridgevlan, $ifacevlan);
}

sub activate_bridge_vlan {
    my ($bridge, $tag_param) = @_;

    die "bridge '$bridge' is not active\n" if ! -d "/sys/class/net/$bridge";

    return $bridge if !defined($tag_param); # no vlan, simply return

    my $tag = int($tag_param);

    die "got strange vlan tag '$tag_param'\n" if $tag < 1 || $tag > 4094;

    my $bridgevlan = "${bridge}v$tag";

    my @ifaces = ();
    my $dir = "/sys/class/net/$bridge/brif";
    PVE::Tools::dir_glob_foreach($dir, '((eth|bond)\d+)', sub {
        push @ifaces, $_[0];
    });

    die "no physical interface on bridge '$bridge'\n" if scalar(@ifaces) == 0;

    # add bridgevlan if it doesn't already exist
    if (! -d "/sys/class/net/$bridgevlan") {
        system("/sbin/brctl addbr $bridgevlan") == 0 ||
            die "can't add bridge $bridgevlan\n";
    }

    # for each physical interface (eth or bridge) bind them to bridge vlan
    foreach my $iface (@ifaces) {
        activate_bridge_vlan_slave($bridgevlan, $iface, $tag);
    }

    #fixme: set other bridge flags

    # be sure to have the bridge up
    system("/sbin/ip link set $bridgevlan up") == 0 ||
        die "can't up bridge $bridgevlan\n";
   
    return $bridgevlan;
}

1;
