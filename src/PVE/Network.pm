package PVE::Network;

use strict;
use warnings;

use PVE::INotify;
use PVE::ProcFSTools;
use PVE::Tools qw(run_command lock_file);

use File::Basename;
use IO::Socket::IP;
use JSON;
use Net::IP;
use NetAddr::IP qw(:lower);
use POSIX qw(ECONNREFUSED);
use Socket qw(NI_NUMERICHOST NI_NUMERICSERV);

# host network related utility functions

our $PHYSICAL_NIC_RE = qr/(?:eth\d+|en[^:.]+|ib[^:.]+)/;

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
    '255.0.0.0' => 8,
    '255.128.0.0' => 9,
    '255.192.0.0' => 10,
    '255.224.0.0' => 11,
    '255.240.0.0' => 12,
    '255.248.0.0' => 13,
    '255.252.0.0' => 14,
    '255.254.0.0' => 15,
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
    '255.255.255.254' => 31,
    '255.255.255.255' => 32,
};

sub setup_tc_rate_limit {
    my ($iface, $rate, $burst) = @_;

    # these are allowed / expected to fail, e.g. when there is no previous rate limit to remove
    eval { run_command("/sbin/tc class del dev $iface parent 1: classid 1:1 >/dev/null 2>&1"); };
    eval { run_command("/sbin/tc filter del dev $iface parent ffff: protocol all pref 50 u32 >/dev/null 2>&1"); };
    eval { run_command("/sbin/tc qdisc del dev $iface ingress >/dev/null 2>&1"); };
    eval { run_command("/sbin/tc qdisc del dev $iface root >/dev/null 2>&1"); };

    return if !$rate;

    # tbf does not work for unknown reason
    #$TC qdisc add dev $DEV root tbf rate $RATE latency 100ms burst $BURST
    # so we use htb instead
    run_command("/sbin/tc qdisc add dev $iface root handle 1: htb default 1");
    run_command("/sbin/tc class add dev $iface parent 1: classid 1:1 " .
		"htb rate ${rate}bps burst ${burst}b");

    run_command("/sbin/tc qdisc add dev $iface handle ffff: ingress");
    run_command(
        "/sbin/tc filter add dev $iface parent ffff: prio 50 basic police rate ${rate}bps burst ${burst}b mtu 64kb drop");

    return;
}

sub tap_rate_limit {
    my ($iface, $rate) = @_;

    $rate = int($rate*1024*1024) if $rate;
    my $burst = 1024*1024;

    setup_tc_rate_limit($iface, $rate, $burst);

    return;
}

sub read_bridge_mtu {
    my ($bridge) = @_;

    my $mtu = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/mtu");
    die "bridge '$bridge' does not exist\n" if !$mtu;

    if ($mtu =~ /^(\d+)$/) { # avoid insecure dependency (untaint)
	$mtu = int($1);
    } else {
	die "unexpeted error: unable to parse mtu value '$mtu' as integer\n";
    }

    return $mtu;
}

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
	return if $noerr;
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

sub check_iface_name : prototype($) {
    my ($name) = @_;

    my $name_len = length($name);

    # iproute2 / kernel have a strict interface name size limit
    die "the interface name $name is too long"
	if $name_len >= PVE::ProcFSTools::IFNAMSIZ;

    # iproute2 checks with isspace(3), which includes vertical tabs (not catched with perl's '\s')
    die "the interface name $name is empty or contains invalid characters"
	if $name_len == 0 || $name =~ /\s|\v|\//;

    return 1;
}

sub iface_delete :prototype($) {
    my ($iface) = @_;
    run_command(['/sbin/ip', 'link', 'delete', 'dev', $iface], noerr => 1)
	== 0 or die "failed to delete interface '$iface'\n";
    return;
}

sub iface_create :prototype($$@) {
    my ($iface, $type, @args) = @_;

    eval { check_iface_name($iface) };
    die "failed to create interface '$iface' - $@" if $@;

    run_command(['/sbin/ip', 'link', 'add', $iface, 'type', $type, @args], noerr => 1)
	== 0 or die "failed to create interface '$iface'\n";
    return;
}

sub iface_set :prototype($@) {
    my ($iface, @opts) = @_;
    run_command(['/sbin/ip', 'link', 'set', $iface, @opts], noerr => 1)
	== 0 or die "failed to set interface options for '$iface' (".join(' ', @opts).")\n";
    return;
}

# helper for nicer error messages:
sub iface_set_master :prototype($$) {
    my ($iface, $master) = @_;
    if (defined($master)) {
	eval { iface_set($iface, 'master', $master) };
	die "can't enslave '$iface' to '$master'\n" if $@;
    } else {
	eval { iface_set($iface, 'nomaster') };
	die "can't unenslave '$iface'\n" if $@;
    }
    return;
}

my $cond_create_bridge = sub {
    my ($bridge) = @_;

    if (! -d "/sys/class/net/$bridge") {
	iface_create($bridge, 'bridge');
	disable_ipv6($bridge);
    }
};

sub disable_ipv6 {
    my ($iface) = @_;
    my $file = "/proc/sys/net/ipv6/conf/$iface/disable_ipv6";
    return if !-e $file; # ipv6 might be completely disabled
    open(my $fh, '>', $file) or die "failed to open $file for writing: $!\n";
    print {$fh} "1\n" or die "failed to disable link-local ipv6 for $iface\n";
    close($fh);
    return;
}

my $bridge_enable_port_isolation = sub {
   my ($iface) = @_;

   eval { run_command(['/sbin/bridge', 'link', 'set', 'dev', $iface, 'isolated', 'on']) };
   die "unable to enable port isolation on interface $iface - $@\n" if $@;
};

my $bridge_disable_interface_learning = sub {
    my ($iface) = @_;

    PVE::ProcFSTools::write_proc_entry("/sys/class/net/$iface/brport/unicast_flood", "0");
    PVE::ProcFSTools::write_proc_entry("/sys/class/net/$iface/brport/learning", "0");

};

my $bridge_add_interface = sub {
    my ($bridge, $iface, $tag, $trunks) = @_;

    my $bridgemtu = read_bridge_mtu($bridge);
    eval { run_command(['/sbin/ip', 'link', 'set', $iface, 'mtu', $bridgemtu]) };

    # drop link local address (it can't be used when on a bridge anyway)
    disable_ipv6($iface);
    iface_set_master($iface, $bridge);

   my $vlan_aware = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/bridge/vlan_filtering");

   if ($vlan_aware) {

        eval { run_command(['/sbin/bridge', 'vlan', 'del', 'dev', $iface, 'vid', '1-4094']) };
        die "failed to remove default vlan tags of $iface - $@\n" if $@;

        if ($trunks) {
            my @trunks_array = split /;/, $trunks;
            foreach my $trunk (@trunks_array) {
                eval { run_command(['/sbin/bridge', 'vlan', 'add', 'dev', $iface, 'vid', $trunk]) };
                die "unable to add vlan $trunk to interface $iface - $@\n" if $@;
            }
        } elsif (!$tag) {
            eval { run_command(['/sbin/bridge', 'vlan', 'add', 'dev', $iface, 'vid', '2-4094']) };
            die "unable to add default vlan tags to interface $iface - $@\n" if $@;
        }

        $tag = 1 if !$tag;
        eval { run_command(['/sbin/bridge', 'vlan', 'add', 'dev', $iface, 'vid', $tag, 'pvid', 'untagged']) };
        die "unable to add vlan $tag to interface $iface - $@\n" if $@;
   }
};

my $ovs_bridge_add_port = sub {
    my ($bridge, $iface, $tag, $internal, $trunks) = @_;

    $trunks =~ s/;/,/g if $trunks;

    my $cmd = ['/usr/bin/ovs-vsctl'];
    # first command
    push @$cmd, '--', 'add-port', $bridge, $iface;
    push @$cmd, "tag=$tag" if $tag;
    push @$cmd, "trunks=". join(',', $trunks) if $trunks;
    push @$cmd, "vlan_mode=native-untagged" if $tag && $trunks;

    my $bridgemtu = read_bridge_mtu($bridge);
    push @$cmd, '--', 'set', 'Interface', $iface, "mtu_request=$bridgemtu";

    if ($internal) {
	# second command
	push @$cmd, '--', 'set', 'Interface', $iface, 'type=internal';
    }

    eval { run_command($cmd) };
    die "can't add ovs port '$iface' - $@\n" if $@;

    disable_ipv6($iface);
};

my $activate_interface = sub {
    my ($iface, $mtu) = @_;

    my $cmd = ['/sbin/ip', 'link', 'set', $iface, 'up'];
    push @$cmd, ('mtu', $mtu) if $mtu;

    eval { run_command($cmd) };
    die "can't activate interface '$iface' - $@\n" if $@;
};

sub add_bridge_fdb {
    my ($iface, $mac) = @_;

    my $learning = PVE::Tools::file_read_firstline("/sys/class/net/$iface/brport/learning");
    return if !defined($learning) || $learning == 1;

    my ($vmid, $devid) = $parse_tap_device_name->($iface, 1);
    return if !defined($vmid);

    run_command(['/sbin/bridge', 'fdb', 'append', $mac, 'dev', $iface, 'master', 'static']);

    my ($fwbr, $vethfw, $vethfwpeer, $ovsintport) = $compute_fwbr_names->($vmid, $devid);

    if (-d "/sys/class/net/$vethfwpeer") {
	run_command(['/sbin/bridge', 'fdb', 'append', $mac, 'dev', $vethfwpeer, 'master', 'static']);
    }

    return;
}

sub del_bridge_fdb {
    my ($iface, $mac) = @_;

    my $learning = PVE::Tools::file_read_firstline("/sys/class/net/$iface/brport/learning");
    return if !defined($learning) || $learning == 1;

    my ($vmid, $devid) = $parse_tap_device_name->($iface, 1);
    return if !defined($vmid);

    run_command(['/sbin/bridge', 'fdb', 'del', $mac, 'dev', $iface, 'master', 'static']);

    my ($fwbr, $vethfw, $vethfwpeer, $ovsintport) = $compute_fwbr_names->($vmid, $devid);

    if (-d "/sys/class/net/$vethfwpeer") {
	run_command(['/sbin/bridge', 'fdb', 'del', $mac, 'dev', $vethfwpeer, 'master', 'static']);
    }

    return;
}

sub tap_create {
    my ($iface, $bridge) = @_;

    die "unable to get bridge setting\n" if !$bridge;

    my $bridgemtu = read_bridge_mtu($bridge);

    eval {
	disable_ipv6($iface);
	run_command(['/sbin/ip', 'link', 'set', $iface, 'up', 'promisc', 'on', 'mtu', $bridgemtu]);
    };
    die "interface activation failed\n" if $@;
    return;
}

sub veth_create {
    my ($veth, $vethpeer, $bridge, $mac) = @_;

    die "unable to get bridge setting\n" if !$bridge;

    my $bridgemtu = read_bridge_mtu($bridge);

    # create veth pair
    if (! -d "/sys/class/net/$veth") {
	eval {
	    check_iface_name($veth);

	    my $cmd = ['/sbin/ip', 'link', 'add'];
	    # veth device + MTU
	    push @$cmd, 'name', $veth;
	    push @$cmd, 'mtu', $bridgemtu;
	    push @$cmd, 'type', 'veth';
	    # peer device + MTU
	    push @$cmd, 'peer', 'name', $vethpeer, 'mtu', $bridgemtu;

	    push @$cmd, 'addr', $mac if $mac;

	    run_command($cmd);
	};
	die "can't create interface $veth - $@\n" if $@;
    }

    # up vethpair
    disable_ipv6($veth);
    disable_ipv6($vethpeer);
    $activate_interface->($veth, $bridgemtu);
    $activate_interface->($vethpeer, $bridgemtu);

    return;
}

sub veth_delete {
    my ($veth) = @_;

    if (-d "/sys/class/net/$veth") {
	iface_delete($veth);
    }
    eval { tap_unplug($veth) };
    return;
}

my $create_firewall_bridge_linux = sub {
    my ($iface, $bridge, $tag, $trunks, $no_learning, $isolation) = @_;

    my ($vmid, $devid) = $parse_tap_device_name->($iface);
    my ($fwbr, $vethfw, $vethfwpeer) = $compute_fwbr_names->($vmid, $devid);

    my $bridgemtu = read_bridge_mtu($bridge);

    $cond_create_bridge->($fwbr);
    $activate_interface->($fwbr, $bridgemtu);

    copy_bridge_config($bridge, $fwbr);
    veth_create($vethfw, $vethfwpeer, $bridge);

    $bridge_add_interface->($bridge, $vethfwpeer, $tag, $trunks);
    $bridge_disable_interface_learning->($vethfwpeer) if $no_learning;
    $bridge_enable_port_isolation->($vethfwpeer) if $isolation;
    $bridge_add_interface->($fwbr, $vethfw);

    $bridge_add_interface->($fwbr, $iface);
};

my $create_firewall_bridge_ovs = sub {
    my ($iface, $bridge, $tag, $trunks, $no_learning) = @_;

    my ($vmid, $devid) = $parse_tap_device_name->($iface);
    my ($fwbr, undef, undef, $ovsintport) = $compute_fwbr_names->($vmid, $devid);

    my $bridgemtu = read_bridge_mtu($bridge);

    $cond_create_bridge->($fwbr);
    $activate_interface->($fwbr, $bridgemtu);

    $bridge_add_interface->($fwbr, $iface);

    $ovs_bridge_add_port->($bridge, $ovsintport, $tag, 1, $trunks);
    $activate_interface->($ovsintport, $bridgemtu);

    $bridge_add_interface->($fwbr, $ovsintport);
    $bridge_disable_interface_learning->($ovsintport) if $no_learning;
};

my $cleanup_firewall_bridge = sub {
    my ($iface) = @_;

    my ($vmid, $devid) = $parse_tap_device_name->($iface, 1);
    return if !defined($vmid);
    my ($fwbr, $vethfw, $vethfwpeer, $ovsintport) = $compute_fwbr_names->($vmid, $devid);

    # cleanup old port config from any openvswitch bridge
    if (-d "/sys/class/net/$ovsintport") {
	run_command("/usr/bin/ovs-vsctl del-port $ovsintport", outfunc => sub {}, errfunc => sub {});
    }

    # delete old vethfw interface
    veth_delete($vethfw);

    # cleanup fwbr bridge
    if (-d "/sys/class/net/$fwbr") {
	iface_delete($fwbr);
    }
};

sub tap_plug {
    my ($iface, $bridge, $tag, $firewall, $trunks, $rate, $opts) = @_;

    $opts = {} if !defined($opts);
    $opts = { learning => $opts } if !ref($opts); # FIXME: backward compat, drop with PVE 8.0

    if (!defined($opts->{learning})) { # auto-detect
	$opts = {} if !defined($opts);
	my $interfaces_config = PVE::INotify::read_file('interfaces');
	my $bridge = $interfaces_config->{ifaces}->{$bridge};
	$opts->{learning} = !($bridge && $bridge->{'bridge-disable-mac-learning'}); # default learning to on
    }
    my $no_learning = !$opts->{learning};
    my $isolation = $opts->{isolation};

    # cleanup old port config from any openvswitch bridge
    eval {
	run_command("/usr/bin/ovs-vsctl del-port $iface", outfunc => sub {}, errfunc => sub {});
    };

    if (-d "/sys/class/net/$bridge/bridge") {
	$cleanup_firewall_bridge->($iface); # remove stale devices

	my $vlan_aware = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/bridge/vlan_filtering");

	if (!$vlan_aware) {
	    die "vlan aware feature need to be enabled to use trunks" if $trunks;
	    my $newbridge = activate_bridge_vlan($bridge, $tag);
	    copy_bridge_config($bridge, $newbridge) if $bridge ne $newbridge;
	    $bridge = $newbridge;
	    $tag = undef;
	}

	if ($firewall) {
	    $create_firewall_bridge_linux->($iface, $bridge, $tag, $trunks, $no_learning, $isolation);
	} else {
	    $bridge_add_interface->($bridge, $iface, $tag, $trunks);
	}
	if ($no_learning) {
	    $bridge_disable_interface_learning->($iface);
	    add_bridge_fdb($iface, $opts->{mac}) if defined($opts->{mac});
	}
	$bridge_enable_port_isolation->($iface) if $isolation;

    } else {
	$cleanup_firewall_bridge->($iface); # remove stale devices

	if ($firewall) {
	    $create_firewall_bridge_ovs->($iface, $bridge, $tag, $trunks, $no_learning);
	} else {
	    $ovs_bridge_add_port->($bridge, $iface, $tag, undef, $trunks);
	}
    }

    tap_rate_limit($iface, $rate);

    return;
}

sub tap_unplug {
    my ($iface) = @_;

    my $path = "/sys/class/net/$iface/brport/bridge";
    if (-l $path) {
	my $bridge = basename(readlink($path));
	#avoid insecure dependency;
	($bridge) = $bridge =~ /(\S+)/;

	iface_set_master($iface, undef);
    }

    $cleanup_firewall_bridge->($iface);
    #cleanup old port config from any openvswitch bridge
    eval { run_command("/usr/bin/ovs-vsctl del-port $iface", outfunc => sub {}, errfunc => sub {}) };

    return;
}

sub copy_bridge_config {
    my ($br0, $br1) = @_;

    return if $br0 eq $br1;

    my $br_configs = [
	'ageing_time', 'stp_state', 'priority', 'forward_delay',
	'hello_time', 'max_age', 'multicast_snooping', 'multicast_querier',
    ];

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
    return;
}

sub activate_bridge_vlan_slave {
    my ($bridgevlan, $iface, $tag) = @_;
    my $ifacevlan = "${iface}.$tag";

    # create vlan on $iface is not already exist
    if (! -d "/sys/class/net/$ifacevlan") {
	eval {
	    check_iface_name($ifacevlan);

	    my $cmd = ['/sbin/ip', 'link', 'add'];
	    push @$cmd, 'link', $iface;
	    push @$cmd, 'name', $ifacevlan;
	    push @$cmd, 'type', 'vlan', 'id', $tag;
	    run_command($cmd);
	};
	die "can't add vlan tag $tag to interface $iface - $@\n" if $@;

	# remove ipv6 link-local address before activation
	disable_ipv6($ifacevlan);
    }

    # be sure to have the $ifacevlan up
    $activate_interface->($ifacevlan);

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
    $bridge_add_interface->($bridgevlan, $ifacevlan);
    return;
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
    PVE::Tools::dir_glob_foreach($dir, '(((eth|bond)\d+|en[^.]+)(\.\d+)?)', sub {
        push @ifaces, $_[0];
    });

    die "no physical interface on bridge '$bridge'\n" if scalar(@ifaces) == 0;

    lock_network(sub {
	# add bridgevlan if it doesn't already exist
	if (! -d "/sys/class/net/$bridgevlan") {
	    iface_create($bridgevlan, 'bridge');
	}

	my $bridgemtu = read_bridge_mtu($bridge);
	eval { run_command(['/sbin/ip', 'link', 'set', $bridgevlan, 'mtu', $bridgemtu]) };

	# for each physical interface (eth or bridge) bind them to bridge vlan
	foreach my $iface (@ifaces) {
	    activate_bridge_vlan_slave($bridgevlan, $iface, $tag);
	}

	#fixme: set other bridge flags

	# remove ipv6 link-local address before activation
	disable_ipv6($bridgevlan);
	# be sure to have the bridge up
	$activate_interface->($bridgevlan);
    });
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

    my ($ip, $prefix) = $cidr =~ m!^(\S+?)/(\S+)$! or return;

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
    return if !$cidr_obj;

    my $ip_obj = Net::IP->new($ip, $version);
    return if !$ip_obj;

    my $overlap = $cidr_obj->overlaps($ip_obj);
    return if !defined($overlap);

    return $overlap == $Net::IP::IP_B_IN_A_OVERLAP || $overlap == $Net::IP::IP_IDENTICAL;
}

# get all currently configured addresses that have a global scope, i.e., are reachable from the
# outside of the host and thus are neither loopback nor link-local ones
# returns an array ref of: { addr => "IP", cidr => "IP/PREFIXLEN", family => "inet|inet6" }
sub get_reachable_networks {
    my $raw = '';
    run_command([qw(ip -j addr show up scope global)], outfunc => sub { $raw .= shift });
    my $decoded = decode_json($raw);

    my $addrs = []; # filter/transform first so that we can sort correctly more easily below
    for my $e ($decoded->@*) {
	next if !$e->{addr_info} || grep { $_ eq 'LOOPBACK' } $e->{flags}->@*;
	push $addrs->@*, grep { scalar(keys $_->%*) } $e->{addr_info}->@*
    }
    my $res = [];
    for my $info (sort { $a->{family} cmp $b->{family} || $a->{local} cmp $b->{local} } $addrs->@*) {
	push $res->@*, {
	    addr => $info->{local},
	    cidr => "$info->{local}/$info->{prefixlen}",
	    family => $info->{family},
	};
    }

    return $res;
}

# get one or all local IPs that are not loopback ones, able to pick up the following ones (in order)
# - the hostname primary resolves too, follows gai.conf (admin controlled) and will be prioritised
# - all configured in the interfaces configuration
# - all currently networks known to the kernel in the current (root) namespace
# returns a single address if no parameter is passed, and all found, grouped by type, if `all => 1`
# is passed.
sub get_local_ip {
    my (%param) = @_;

    my $nodename = PVE::INotify::nodename();
    my $resolved_host = eval { get_ip_from_hostname($nodename) };

    return $resolved_host if defined($resolved_host) && !$param{all};

    my $all = { v4 => {}, v6 => {} }; # hash to avoid duplicates and group by type

    my $interaces_cfg = PVE::INotify::read_file('interfaces', 1) || {};
    for my $if (values $interaces_cfg->{data}->{ifaces}->%*) {
	next if $if->{type} eq 'loopback' || (!defined($if->{address}) && !defined($if->{address6}));
	my ($v4, $v6) = ($if->{address}, $if->{address6});

	return ($v4 // $v6) if !$param{all}; # prefer v4, admin can override $resolved_host via hosts/gai.conf

	$all->{v4}->{$v4} = 1 if defined($v4);
	$all->{v6}->{$v6} = 1 if defined($v6);
    }

    my $live = eval { get_reachable_networks() } // [];
    for my $info ($live->@*) {
	my $addr = $info->{addr};

	return $addr if !$param{all};

	if ($info->{family} eq 'inet') {
	    $all->{v4}->{$addr} = 1;
	} else {
	    $all->{v6}->{$addr} = 1;
	}
    }

    return if !$param{all}; # getting here means no early return above triggered -> no IPs

    my $res = []; # order gai.conf controlled first, then group v4 and v6, simply lexically sorted
    if ($resolved_host) {
	push $res->@*, $resolved_host;
	delete $all->{v4}->{$resolved_host};
	delete $all->{v6}->{$resolved_host};
    }
    push $res->@*, sort { $a cmp $b } keys $all->{v4}->%*;
    push $res->@*, sort { $a cmp $b } keys $all->{v6}->%*;

    return $res;
}

sub get_local_ip_from_cidr {
    my ($cidr) = @_;

    my $IPs = {};
    my $i = 1;
    run_command(['/sbin/ip', 'address', 'show', 'to', $cidr, 'up'], outfunc => sub {
	if ($_[0] =~ m!^\s*inet(?:6)?\s+($PVE::Tools::IPRE)(?:/\d+|\s+peer\s+)!) {
	    $IPs->{$1} = $i++ if !exists($IPs->{$1});
	}
    });

    return [ sort { $IPs->{$a} <=> $IPs->{$b} } keys %{$IPs} ];
}

sub addr_to_ip {
    my ($addr) = @_;
    my ($err, $host, $port) = Socket::getnameinfo($addr, NI_NUMERICHOST | NI_NUMERICSERV);
    die "failed to get numerical host address: $err\n" if $err;
    return ($host, $port) if wantarray;
    return $host;
}

sub get_ip_from_hostname {
    my ($hostname, $noerr) = @_;

    my @res = eval { PVE::Tools::getaddrinfo_all($hostname) };
    if ($@) {
	die "hostname lookup '$hostname' failed - $@" if !$noerr;
	return;
    }

    for my $ai (@res) {
	my $ip = addr_to_ip($ai->{addr});
	if ($ip !~ m/^127\.|^::1$/) {
	    return wantarray ? ($ip, $ai->{family}) : $ip;
	}
    }
    # NOTE: we only get here if no WAN/LAN IP was found, so this is now the error path!
    die "address lookup for '$hostname' did not find any IP address\n" if !$noerr;
    return;
}

sub lock_network {
    my ($code, @param) = @_;
    my $res = lock_file('/var/lock/pve-network.lck', 10, $code, @param);
    die $@ if $@;
    return $res;
}

# the canonical form of the given IP, i.e. dotted quad for IPv4 and RFC 5952 for IPv6
sub canonical_ip {
    my ($ip) = @_;

    my $ip_obj = NetAddr::IP->new($ip) or die "invalid IP string '$ip'\n";

    return $ip_obj->canon();
}

# List of unique, canonical IPs in the provided list.
# Keeps the original order, filtering later duplicates.
sub unique_ips {
    my ($ips) = @_;

    my $res = [];
    my $seen = {};

    for my $ip (@{$ips}) {
	$ip = canonical_ip($ip);

	next if $seen->{$ip};

	$seen->{$ip} = 1;
	push @{$res}, $ip;
    }

    return $res;
}

1;
