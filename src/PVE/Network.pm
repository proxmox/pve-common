package PVE::Network;

use strict;
use warnings;
use PVE::Tools qw(run_command);
use PVE::ProcFSTools;
use PVE::INotify;
use File::Basename;
use IO::Socket::IP;
use POSIX qw(ECONNREFUSED);

use Net::IP;

use Socket qw(IPPROTO_IP);

use constant IFF_UP => 1;
use constant IFNAMSIZ => 16;
use constant SIOCGIFFLAGS => 0x8913;

# host network related utility functions

our $ipv4_reverse_mask = [
    '0.0.0.0',
    '128.0.0.0',
    '192.0.0.0',
    '224.0.0.0',
    '240.0.0.0',
    '248.0.0.0',
    '252.0.0.0',
    '254.0.0.0',
    '255.0.0.0',
    '255.128.0.0',
    '255.192.0.0',
    '255.224.0.0',
    '255.240.0.0',
    '255.248.0.0',
    '255.252.0.0',
    '255.254.0.0',
    '255.255.0.0',
    '255.255.128.0',
    '255.255.192.0',
    '255.255.224.0',
    '255.255.240.0',
    '255.255.248.0',
    '255.255.252.0',
    '255.255.254.0',
    '255.255.255.0',
    '255.255.255.128',
    '255.255.255.192',
    '255.255.255.224',
    '255.255.255.240',
    '255.255.255.248',
    '255.255.255.252',
    '255.255.255.254',
    '255.255.255.255',
];

our $ipv4_mask_hash_localnet = {
    '255.255.0.0' => 16,
    '255.255.128.0' => 17,
    '255.255.192.0' => 18,
    '255.255.224.0' => 19,
    '255.255.240.0' => 20,
    '255.255.248.0' => 21,
    '255.255.252.0' => 22,
    '255.255.254.0' => 23,
    '255.255.255.0' => 24,
    '255.255.255.128' => 25,
    '255.255.255.192' => 26,
    '255.255.255.224' => 27,
    '255.255.255.240' => 28,
    '255.255.255.248' => 29,
    '255.255.255.252' => 30,
};

sub setup_tc_rate_limit {
    my ($iface, $rate, $burst, $debug) = @_;

    system("/sbin/tc class del dev $iface parent 1: classid 1:1 >/dev/null 2>&1");
    system("/sbin/tc filter del dev $iface parent ffff: protocol all pref 50 u32 >/dev/null 2>&1");
    system("/sbin/tc qdisc del dev $iface ingress >/dev/null 2>&1");
    system("/sbin/tc qdisc del dev $iface root >/dev/null 2>&1");

    return if !$rate;

    # tbf does not work for unknown reason
    #$TC qdisc add dev $DEV root tbf rate $RATE latency 100ms burst $BURST
    # so we use htb instead
    run_command("/sbin/tc qdisc add dev $iface root handle 1: htb default 1");
    run_command("/sbin/tc class add dev $iface parent 1: classid 1:1 " .
		"htb rate ${rate}bps burst ${burst}b");

    run_command("/sbin/tc qdisc add dev $iface handle ffff: ingress");
    run_command("/sbin/tc filter add dev $iface parent ffff: " .
		"prio 50 basic " .
		"police rate ${rate}bps burst ${burst}b mtu 64kb " .
		"drop flowid :1");

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
    $rate = int($rate*1024*1024) if $rate;
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

my $parse_tap_device_name = sub {
    my ($iface, $noerr) = @_;

    my ($vmid, $devid);

    if ($iface =~ m/^tap(\d+)i(\d+)$/) {
	$vmid = $1;
	$devid = $2;
    } elsif ($iface =~ m/^veth(\d+)i(\d+)$/) {
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
    my ($bridge, $iface, $tag, $trunks) = @_;

    system("/sbin/brctl addif $bridge $iface") == 0 ||
	die "can't add interface 'iface' to bridge '$bridge'\n";

   my $vlan_aware = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/bridge/vlan_filtering");

   if ($vlan_aware) {
	if ($tag) {
	    system("/sbin/bridge vlan add dev $iface vid $tag pvid untagged") == 0 ||
	    die "unable to add vlan $tag to interface $iface\n";
	} else {
	    system("/sbin/bridge vlan add dev $iface vid 2-4094") == 0 ||
	    die "unable to add default vlan tags to interface $iface\n" if !$trunks;
	} 

	if ($trunks) {
	    my @trunks_array = split /;/, $trunks;
	    foreach my $trunk (@trunks_array) { 
		system("/sbin/bridge vlan add dev $iface vid $trunk") == 0 ||
		die "unable to add vlan $trunk to interface $iface\n";
	    }
	}
   }
};

my $ovs_bridge_add_port = sub {
    my ($bridge, $iface, $tag, $internal, $trunks) = @_;

    $trunks =~ s/;/,/g if $trunks;

    my $cmd = "/usr/bin/ovs-vsctl add-port $bridge $iface";
    $cmd .= " tag=$tag" if $tag;
    $cmd .= " trunks=". join(',', $trunks) if $trunks;
    $cmd .= " vlan_mode=native-untagged" if $tag && $trunks;

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

sub veth_create {
    my ($veth, $vethpeer, $bridge, $mac) = @_;

    die "unable to get bridge setting\n" if !$bridge;

    my $bridgemtu = &$read_bridge_mtu($bridge);

    # create veth pair
    if (! -d "/sys/class/net/$veth") {
	my $cmd = "/sbin/ip link add name $veth type veth peer name $vethpeer mtu $bridgemtu";
	$cmd .= " addr $mac" if $mac;
	system($cmd) == 0 || die "can't create interface $veth\n";
    }

    # up vethpair
    &$activate_interface($veth);
    &$activate_interface($vethpeer);
}

sub veth_delete {
    my ($veth) = @_;

    if (-d "/sys/class/net/$veth") {
	run_command("/sbin/ip link delete dev $veth", outfunc => sub {}, errfunc => sub {});
    }

}

my $create_firewall_bridge_linux = sub {
    my ($iface, $bridge, $tag, $trunks) = @_;

    my ($vmid, $devid) = &$parse_tap_device_name($iface);
    my ($fwbr, $vethfw, $vethfwpeer) = &$compute_fwbr_names($vmid, $devid);

    &$cond_create_bridge($fwbr);
    &$activate_interface($fwbr);

    copy_bridge_config($bridge, $fwbr);
    veth_create($vethfw, $vethfwpeer, $bridge);

    &$bridge_add_interface($fwbr, $vethfw);
    &$bridge_add_interface($bridge, $vethfwpeer, $tag, $trunks);

    &$bridge_add_interface($fwbr, $iface);
};

my $create_firewall_bridge_ovs = sub {
    my ($iface, $bridge, $tag, $trunks) = @_;

    my ($vmid, $devid) = &$parse_tap_device_name($iface);
    my ($fwbr, undef, undef, $ovsintport) = &$compute_fwbr_names($vmid, $devid);

    my $bridgemtu = &$read_bridge_mtu($bridge);

    &$cond_create_bridge($fwbr);
    &$activate_interface($fwbr);

    &$bridge_add_interface($fwbr, $iface);

    &$ovs_bridge_add_port($bridge, $ovsintport, $tag, 1, $trunks);
    &$activate_interface($ovsintport);

    # set the same mtu for ovs int port
    PVE::Tools::run_command("/sbin/ifconfig $ovsintport mtu $bridgemtu");
    
    &$bridge_add_interface($fwbr, $ovsintport);
};

my $cleanup_firewall_bridge = sub {
    my ($iface) = @_;

    my ($vmid, $devid) = &$parse_tap_device_name($iface, 1);
    return if !defined($vmid);  
    my ($fwbr, $vethfw, $vethfwpeer, $ovsintport) = &$compute_fwbr_names($vmid, $devid);

    # cleanup old port config from any openvswitch bridge
    if (-d "/sys/class/net/$ovsintport") {
	run_command("/usr/bin/ovs-vsctl del-port $ovsintport", outfunc => sub {}, errfunc => sub {});
    }

    # delete old vethfw interface
    veth_delete($vethfw);

    # cleanup fwbr bridge
    if (-d "/sys/class/net/$fwbr") {
	run_command("/sbin/ip link set dev $fwbr down", outfunc => sub {}, errfunc => sub {});
	run_command("/sbin/brctl delbr $fwbr", outfunc => sub {}, errfunc => sub {});
    }
};

sub tap_plug {
    my ($iface, $bridge, $tag, $firewall, $trunks, $rate) = @_;

    #cleanup old port config from any openvswitch bridge
    eval {run_command("/usr/bin/ovs-vsctl del-port $iface", outfunc => sub {}, errfunc => sub {}) };

    if (-d "/sys/class/net/$bridge/bridge") {
	&$cleanup_firewall_bridge($iface); # remove stale devices

	my $vlan_aware = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/bridge/vlan_filtering");

	if (!$vlan_aware) {
	    die "vlan aware feature need to be enabled to use trunks" if $trunks;
	    my $newbridge = activate_bridge_vlan($bridge, $tag);
	    copy_bridge_config($bridge, $newbridge) if $bridge ne $newbridge;
	    $bridge = $newbridge;
	    $tag = undef;
	}

	if ($firewall) {
	    &$create_firewall_bridge_linux($iface, $bridge, $tag, $trunks);
	} else {
	    &$bridge_add_interface($bridge, $iface, $tag, $trunks);
	}

    } else {
	&$cleanup_firewall_bridge($iface); # remove stale devices

	if ($firewall) {
	    &$create_firewall_bridge_ovs($iface, $bridge, $tag, $trunks);
	} else {
	    &$ovs_bridge_add_port($bridge, $iface, $tag, undef, $trunks);
	}
    }

    tap_rate_limit($iface, $rate);
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
	system("/sbin/ip link add link $iface name ${iface}.${tag} type vlan id $tag") == 0 ||
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
    PVE::Tools::dir_glob_foreach($dir, '((eth|bond)\d+(\.\d+)?)', sub {
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

sub tcp_ping {
    my ($host, $port, $timeout) = @_;

    my $refused = 1;

    $timeout = 3 if !$timeout; # sane default
    if (!$port) {
	# Net::Ping defaults to the echo port
	$port = 7;
    } else {
	# Net::Ping's port_number() implies service_check(1)
	$refused = 0;
    }

    my ($sock, $result);
    eval {
	$result = PVE::Tools::run_with_timeout($timeout, sub {
	    $sock = IO::Socket::IP->new(PeerHost => $host, PeerPort => $port, Type => SOCK_STREAM);
	    $result = $refused if $! == ECONNREFUSED;
	});
    };
    if ($sock) {
	$sock->close();
	$result = 1;
    }
    return $result;
}

sub IP_from_cidr {
    my ($cidr, $version) = @_;

    return if $cidr !~ m!^(\S+?)/(\S+)$!;
    my ($ip, $prefix) = ($1, $2);

    my $ipobj = Net::IP->new($ip, $version);
    return if !$ipobj;

    $version = $ipobj->version();

    my $binmask = Net::IP::ip_get_mask($prefix, $version);
    return if !$binmask;

    my $masked_binip = $ipobj->binip() & $binmask;
    my $masked_ip = Net::IP::ip_bintoip($masked_binip, $version);
    return Net::IP->new("$masked_ip/$prefix");
}

sub is_ip_in_cidr {
    my ($ip, $cidr, $version) = @_;

    my $cidr_obj = IP_from_cidr($cidr, $version);
    return undef if !$cidr_obj;

    my $ip_obj = Net::IP->new($ip, $version);
    return undef if !$ip_obj;

    return $cidr_obj->overlaps($ip_obj) == $Net::IP::IP_B_IN_A_OVERLAP;
}

# struct ifreq { // FOR SIOCGIFFLAGS:
#   char ifrn_name[IFNAMSIZ]
#   short ifru_flags
# };
my $STRUCT_IFREQ_SIOCGIFFLAGS = 'Z' . IFNAMSIZ . 's1';
sub get_active_interfaces {
    # Use the interface name list from /proc/net/dev
    open my $fh, '<', '/proc/net/dev'
	or die "failed to open /proc/net/dev: $!\n";
    # And filter by IFF_UP flag fetched via a PF_INET6 socket ioctl:
    my $sock;
    socket($sock, PF_INET6, SOCK_DGRAM, &IPPROTO_IP)
    or socket($sock, PF_INET, SOCK_DGRAM, &IPPROTO_IP)
    or return [];

    my $ifaces = [];
    while(defined(my $line = <$fh>)) {
	next if $line !~ /^\s*([^:\s]+):/;
	my $ifname = $1;
	my $ifreq = pack($STRUCT_IFREQ_SIOCGIFFLAGS, $ifname, 0);
	if (!defined(ioctl($sock, SIOCGIFFLAGS, $ifreq))) {
	    warn "failed to get interface flags for: $ifname\n";
	    next;
	}
	my ($name, $flags) = unpack($STRUCT_IFREQ_SIOCGIFFLAGS, $ifreq);
	push @$ifaces, $ifname if ($flags & IFF_UP);
    }
    close $fh;
    close $sock;
    return $ifaces;
}

1;
