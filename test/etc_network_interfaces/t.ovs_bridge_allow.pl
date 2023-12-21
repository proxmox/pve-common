use strict;

my $ip = '192.168.0.100/24';
my $gw = '192.168.0.1';

# replace proc_net_dev with one with a bunch of interfaces
save('proc_net_dev', <<'/proc/net/dev');
eth0:
eth1:
eth2:
eth3:
/proc/net/dev

r('');

new_iface('vmbr0', 'OVSBridge',
    [ { family => 'inet',
        address => $ip,
        gateway => $gw } ],
    autostart => 1);

update_iface('eth0', [], autostart => 1);
update_iface('eth1', [], autostart => 1);
update_iface('eth2', [], autostart => 1);
#update_iface('eth3', [], autostart => 1);

# Check the bridge and eth interfaces
expect load('loopback') . <<"/etc/network/interfaces";
auto eth0
iface eth0 inet manual

auto eth1
iface eth1 inet manual

auto eth2
iface eth2 inet manual

iface eth3 inet manual

auto vmbr0
iface vmbr0 inet static
	address $ip
	gateway $gw
	ovs_type OVSBridge

/etc/network/interfaces

# Adding an interface to the bridge needs to add allow- lines and remove
# its autostart property.
update_iface('vmbr0', [], ovs_ports => 'eth1 eth2');
expect load('loopback') . <<"/etc/network/interfaces";
auto eth0
iface eth0 inet manual

auto eth1
iface eth1 inet manual
	ovs_type OVSPort
	ovs_bridge vmbr0

auto eth2
iface eth2 inet manual
	ovs_type OVSPort
	ovs_bridge vmbr0

iface eth3 inet manual

auto vmbr0
iface vmbr0 inet static
	address $ip
	gateway $gw
	ovs_type OVSBridge
	ovs_ports eth1 eth2

/etc/network/interfaces

# Idempotency - make sure "allow-$BRIDGE $IFACE" don't get duplicated
# they're stripped from $config->{options} at load-time since they're
# auto-generated when writing OVSPorts.
save('idem', w());
r(load('idem'));
expect load('idem');

# Removing an ovs_port also has to remove the corresponding allow- line!
# Also remember that adding interfaces to the ovs bridge removed their
# autostart property, so eth2 is now without an autostart!
update_iface('vmbr0', [], ovs_ports => 'eth1');
# eth2 is now autoremoved and thus loses its priority, so it appears after eth3
expect load('loopback') . <<"/etc/network/interfaces";
auto eth0
iface eth0 inet manual

auto eth1
iface eth1 inet manual
	ovs_type OVSPort
	ovs_bridge vmbr0

iface eth3 inet manual

iface eth2 inet manual

auto vmbr0
iface vmbr0 inet static
	address $ip
	gateway $gw
	ovs_type OVSBridge
	ovs_ports eth1

/etc/network/interfaces

1;
