my $base = load('loopback');
sub wanted($) {
    my ($ip) = @_;
    return $base . <<"IFACES";
iface eth0 inet manual

iface eth1 inet manual

iface eth2 inet manual

iface eth3 inet manual

iface eth4 inet manual

iface eth5 inet manual

iface eth6 inet manual

iface eth7 inet manual

iface bond0 inet manual
	slaves eth0 eth1
	bond_miimon 100
	bond_mode balance-alb

auto bond1
iface bond1 inet static
	address  10.10.10.$ip
	netmask  255.255.255.0
	slaves eth2 eth3
	bond_miimon 100
	bond_mode balance-alb
#       pre-up ifconfig bond1 mtu 9000

auto bond2
iface bond2 inet manual
	slaves eth4 eth5
	bond_miimon 100
	bond_mode balance-alb
# Private networking

iface vlan3 inet static
	address  0.0.0.0
	netmask  0.0.0.0
	vlan_raw_device bond2

iface vlan4 inet static
	address  0.0.0.0
	netmask  0.0.0.0
	vlan_raw_device bond2

iface vlan5 inet static
	address  0.0.0.0
	netmask  0.0.0.0
	vlan_raw_device bond2

auto vmbr0
iface vmbr0 inet static
	address  192.168.100.13
	netmask  255.255.255.0
	gateway  192.168.100.1
	bridge_ports bond0
	bridge_stp off
	bridge_fd 0

auto vlan6
iface vlan6 inet static
	address  10.10.11.13
	netmask  255.255.255.0
	vlan_raw_device bond0
	network 10.10.11.0
	pre-up ifconfig bond0 up

auto vmbr3
iface vmbr3 inet manual
	bridge_ports vlan3
	bridge_stp off
	bridge_fd 0
	pre-up ifup vlan3

auto vmbr4
iface vmbr4 inet manual
	bridge_ports vlan4
	bridge_stp off
	bridge_fd 0
	pre-up ifup vlan4

auto vmbr5
iface vmbr5 inet manual
	bridge_ports vlan5
	bridge_stp off
	bridge_fd 0
	pre-up ifup vlan5

IFACES
}

r(wanted(13));
update_iface('bond1', [ { family => 'inet', address => '10.10.10.11' } ]);
expect wanted(11);

1;
