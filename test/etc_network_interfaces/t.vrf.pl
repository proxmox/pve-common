use JSON;
use Storable qw(dclone);

my $ip_links = decode_json(load('ip_link_details'));

for my $idx (1 .. 2) {
    my $entry = dclone($ip_links->{eth0});
    $entry->{ifname} = "eth$idx";

    $ip_links->{"eth$idx"} = $entry;
}

# The VRF is an interface-wide option: it is read from any stanza and written once, so that
# removing the stanza it was read from does not drop it.
my $dual_stack = <<'EOF';
auto eth1
iface eth1 inet static
	address 192.0.2.10/24
	vrf vrf_zone1

iface eth1 inet6 static
	address 2001:db8::10/64

EOF

r($dual_stack, $ip_links);

die "VRF not parsed as interface option\n"
    if ($config->{ifaces}->{eth1}->{vrf} // '') ne 'vrf_zone1';

expect(load('loopback') . $dual_stack . "iface eth0 inet manual\n\niface eth2 inet manual\n\n");

delete_iface('eth1', 'inet');

my $ipv6_only = <<'EOF';
auto eth1
iface eth1 inet6 static
	address 2001:db8::10/64
	vrf vrf_zone1

EOF

expect(load('loopback') . $ipv6_only . "iface eth0 inet manual\n\niface eth2 inet manual\n\n");

r(w(), $ip_links);
expect(load('loopback') . $ipv6_only . "iface eth0 inet manual\n\niface eth2 inet manual\n\n");

# Bond slaves and bridge ports already have a master and cannot be put into a VRF.
r(<<'EOF', $ip_links);
iface eth1 inet manual

iface eth2 inet manual
	vrf vrf_zone1

auto bond0
iface bond0 inet manual
	bond-slaves eth1 eth2
	bond-miimon 100
	bond-mode active-backup

EOF

eval { w() };
die "VRF on a bond slave was not rejected\n"
    if $@ !~ m/^bond 'bond0' - slave 'eth2' cannot have a VRF master$/m;

r(<<'EOF', $ip_links);
iface eth1 inet manual
	vrf vrf_zone1

auto vmbr0
iface vmbr0 inet manual
	bridge-ports eth1
	bridge-stp off
	bridge-fd 0

EOF

eval { w() };
die "VRF on a bridge port was not rejected\n"
    if $@ !~ m/^bridge 'vmbr0' - port 'eth1' cannot have a VRF master$/m;

# OVS bridges and internal ports are regular devices, OVS ports belong to the OVS datapath
my $ovs = <<'EOF';
auto eth1
iface eth1 inet manual
	ovs_type OVSPort
	ovs_bridge vmbr1

iface eth0 inet manual

iface eth2 inet manual

auto ovsint0
iface ovsint0 inet static
	address 192.0.2.20/24
	ovs_type OVSIntPort
	ovs_bridge vmbr1
	vrf vrf_zone1

auto vmbr1
iface vmbr1 inet manual
	ovs_type OVSBridge
	ovs_ports eth1 ovsint0

EOF

r($ovs, $ip_links);
expect(load('loopback') . $ovs);

my $ovs_port_vrf = $ovs =~ s/^(\tovs_bridge vmbr1\n)\n/$1\tvrf vrf_zone1\n\n/mr;
r($ovs_port_vrf, $ip_links);
eval { w() };
die "VRF on an OVS port was not rejected\n"
    if $@ !~ m/^iface 'eth1' - VRF is not supported on OVS ports and bonds$/m;

1;
