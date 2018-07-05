save('proc_net_dev', <<'/proc/net/dev');
eth0:
eth1:
/proc/net/dev

r(load('brbase'));

my $ip = '192.168.0.2';
my $nm = '255.255.255.0';
my $gw = '192.168.0.1';
my $svcnodeip = '239.192.105.237';
my $physdev = 'eth0';
my $remoteip1 = '192.168.0.3';
my $remoteip2 = '192.168.0.4';


$config->{ifaces}->{eth1} = {
    type => 'eth',
    method => 'static',
    address => $ip,
    netmask => $nm,
    gateway => $gw,
    families => ['inet'],
    autostart => 1
};

$config->{ifaces}->{vmbr1} = {
    type => 'bridge',
    method => 'manual',
    families => ['inet'],
    bridge_stp => off,
    bridge_fd => 0,
    bridge_ports => vxlan1,
    bridge_vlan_aware => yes,
    autostart => 1
};


$config->{ifaces}->{vmbr2} = {
    type => 'bridge',
    method => 'manual',
    families => ['inet'],
    bridge_stp => off,
    bridge_fd => 0,
    bridge_ports => vxlan2,
    autostart => 1
};

$config->{ifaces}->{vmbr3} = {
    type => 'bridge',
    method => 'manual',
    families => ['inet'],
    bridge_stp => off,
    bridge_fd => 0,
    bridge_ports => vxlan3,
    bridge_vlan_aware => yes,
    bridge_vids => '2-10',
    autostart => 1
};

$config->{ifaces}->{vxlan1} = {
    type => 'vxlan',
    method => 'manual',
    families => ['inet'],
    'vxlan-id' => 1,
    'vxlan-svcnodeip' => $svcnodeip,
    'vxlan-physdev' => $physdev,
    autostart => 1
};

$config->{ifaces}->{vxlan2} = {
    type => 'vxlan',
    method => 'manual',
    families => ['inet'],
    'vxlan-id' => 2,
    'vxlan-local-tunnelip' => $ip,
    'bridge-learning' => 'off',
    'bridge-arp-nd-suppress' => 'on',
    'bridge-unicast-flood' => 'off',
    'bridge-multicast-flood' => 'off',
    autostart => 1
};

$config->{ifaces}->{vxlan3} = {
    type => 'vxlan',
    method => 'manual',
    families => ['inet'],
    'vxlan-id' => 3,
    'vxlan-remoteip' => [$remoteip1, $remoteip2],
    'bridge-access' => 3,
    autostart => 1
};


expect load('loopback') . <<"CHECK";
source-directory interfaces.d

iface eth0 inet manual

auto eth1
iface eth1 inet static
	address  $ip
	netmask  $nm
	gateway  $gw

auto vmbr0
iface vmbr0 inet static
	address  10.0.0.2
	netmask  255.255.255.0
	gateway  10.0.0.1
	bridge-ports eth0
	bridge-stp off
	bridge-fd 0

auto vmbr1
iface vmbr1 inet manual
	bridge-ports vxlan1
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 2-4094

auto vmbr2
iface vmbr2 inet manual
	bridge-ports vxlan2
	bridge-stp off
	bridge-fd 0

auto vmbr3
iface vmbr3 inet manual
	bridge-ports vxlan3
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 2-10

auto vxlan1
iface vxlan1 inet manual
	vxlan-id 1
	vxlan-svcnodeip $svcnodeip
	vxlan-physdev $physdev

auto vxlan2
iface vxlan2 inet manual
	vxlan-id 2
	vxlan-local-tunnelip $ip
	bridge-arp-nd-suppress on
	bridge-learning off
	bridge-multicast-flood off
	bridge-unicast-flood off

auto vxlan3
iface vxlan3 inet manual
	vxlan-id 3
	vxlan-remoteip $remoteip1
	vxlan-remoteip $remoteip2
	bridge-access 3

CHECK

save('if', w());
r(load('if'));
expect load('if');

r(load('brbase'));

my $ip = 'fc05::2';
my $nm = '112';
my $gw = 'fc05::1';

$config->{ifaces}->{eth1} = {
    type => 'eth',
    method6 => 'static',
    address6 => $ip,
    netmask6 => $nm,
    gateway6 => $gw,
    families => ['inet6'],
    autostart => 1
};


expect load('loopback') . <<"CHECK";
source-directory interfaces.d

iface eth0 inet manual

auto eth1
iface eth1 inet6 static
	address  $ip
	netmask  $nm
	gateway  $gw

auto vmbr0
iface vmbr0 inet static
	address  10.0.0.2
	netmask  255.255.255.0
	gateway  10.0.0.1
	bridge-ports eth0
	bridge-stp off
	bridge-fd 0

CHECK

save('if', w());
r(load('if'));
expect load('if');

1;
