save('proc_net_dev', <<'/proc/net/dev');
eth0:
eth1:
eth2:
eth3:
eth4:
eth5:
/proc/net/dev

r(load('brbase'));

#
# Variables used for the various interfaces:
#

my $ip = '192.168.0.2/24';
my $gw = '192.168.0.1';
my $svcnodeip = '239.192.105.237';
my $physdev = 'eth0';
my $remoteip1 = '192.168.0.3';
my $remoteip2 = '192.168.0.4';

#
# Hunk for the default bridge of the 'brbase' configuration
#

my $vmbr0_part = <<"PART";
auto vmbr0
iface vmbr0 inet static
	address 10.0.0.2/24
	gateway 10.0.0.1
	bridge-ports eth0
	bridge-stp off
	bridge-fd 0
PART
chomp $vmbr0_part;

#
# Configure eth1 statically, store its expected interfaces hunk in $eth1_part
# and test!
#

$config->{ifaces}->{eth1} = {
    type => 'eth',
    method => 'static',
    address => $ip,
    gateway => $gw,
    families => ['inet'],
    autostart => 1
};

my $eth1_part = <<"PART";
auto eth1
iface eth1 inet static
	address $ip
	gateway $gw
PART
chomp $eth1_part;

expect load('loopback') . <<"CHECK";
source-directory interfaces.d

iface eth0 inet manual

$eth1_part

iface eth2 inet manual

iface eth3 inet manual

iface eth4 inet manual

iface eth5 inet manual

$vmbr0_part

CHECK

#
# Add a bond for eth2 & 3 and check the new output
#

$config->{ifaces}->{bond0} = {
    type => 'bond',
    mtu => 1400,
    slaves => 'eth2 eth3',
    bond_mode => '802.3ad',
    bond_xmit_hash_policy => 'layer3+4',
    bond_miimon => 100,
    method => 'manual',
    families => ['inet'],
    autostart => 1
};
my $bond0_part = <<"PART";
auto bond0
iface bond0 inet manual
	bond-slaves eth2 eth3
	bond-miimon 100
	bond-mode 802.3ad
	bond-xmit-hash-policy layer3+4
	mtu 1400
PART
chomp $bond0_part;

expect load('loopback') . <<"CHECK";
source-directory interfaces.d

iface eth0 inet manual

$eth1_part

auto eth2
iface eth2 inet manual

auto eth3
iface eth3 inet manual

iface eth4 inet manual

iface eth5 inet manual

$bond0_part

$vmbr0_part

CHECK

#
# Add vxlan1 and 2
#

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
    autostart => 1
};

my $vxlan12_part = <<"PART";
auto vxlan1
iface vxlan1 inet manual
	vxlan-id 1
	vxlan-svcnodeip $svcnodeip
	vxlan-physdev $physdev

auto vxlan2
iface vxlan2 inet manual
	vxlan-id 2
	vxlan-local-tunnelip $ip
PART
chomp $vxlan12_part;

expect load('loopback') . <<"CHECK";
source-directory interfaces.d

iface eth0 inet manual

$eth1_part

auto eth2
iface eth2 inet manual

auto eth3
iface eth3 inet manual

iface eth4 inet manual

iface eth5 inet manual

$bond0_part

$vmbr0_part

$vxlan12_part

CHECK

#
# Add vxlan3 and 3 bridges using vxlan1..3
#

$config->{ifaces}->{vmbr1} = {
    mtu => 1400,
    type => 'bridge',
    method => 'manual',
    families => ['inet'],
    bridge_stp => 'off',
    bridge_fd => 0,
    bridge_ports => 'vxlan1',
    bridge_vlan_aware => 'yes',
    autostart => 1
};

$config->{ifaces}->{vmbr2} = {
    type => 'bridge',
    method => 'manual',
    families => ['inet'],
    bridge_stp => 'off',
    bridge_fd => 0,
    bridge_ports => 'vxlan2',
    autostart => 1
};

$config->{ifaces}->{vmbr3} = {
    type => 'bridge',
    method => 'manual',
    families => ['inet'],
    bridge_stp => 'off',
    bridge_fd => 0,
    bridge_ports => 'vxlan3',
    bridge_vlan_aware => 'yes',
    bridge_vids => '2-10',
    autostart => 1
};

my $vmbr123_part = <<"PART";
auto vmbr1
iface vmbr1 inet manual
	bridge-ports vxlan1
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 2-4094
	mtu 1400

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
PART
chomp $vmbr123_part;

$config->{ifaces}->{vxlan3} = {
    type => 'vxlan',
    method => 'manual',
    families => ['inet'],
    'vxlan-id' => 3,
    'vxlan-remoteip' => [$remoteip1, $remoteip2],
    'bridge-access' => 3,
    autostart => 1
};

my $vx = $config->{ifaces}->{vxlan2};
$vx->{'bridge-learning'} = 'off';
$vx->{'bridge-arp-nd-suppress'} = 'on';
$vx->{'bridge-unicast-flood'} = 'off';
$vx->{'bridge-multicast-flood'} = 'off';
my $vxlan123_part = $vxlan12_part ."\n" . <<"PART";
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
PART
chomp $vxlan123_part;

expect load('loopback') . <<"CHECK";
source-directory interfaces.d

iface eth0 inet manual

$eth1_part

auto eth2
iface eth2 inet manual

auto eth3
iface eth3 inet manual

iface eth4 inet manual

iface eth5 inet manual

$bond0_part

$vmbr0_part

$vmbr123_part

$vxlan123_part

CHECK

#
# Now add vlans on all types of interfaces: vmbr1, bond0 and eth1
#

$config->{ifaces}->{'vmbr1.100'} = {
    type => 'vlan',
    mtu => 1300,
    method => 'manual',
    families => ['inet'],
    autostart => 1
};

$config->{ifaces}->{'bond0.100'} = {
    type => 'vlan',
    mtu => 1300,
    method => 'manual',
    families => ['inet'],
    'vlan-protocol' => '802.1ad',
    autostart => 1
};

$config->{ifaces}->{'bond0.100.10'} = {
    type => 'vlan',
    mtu => 1300,
    method => 'manual',
    families => ['inet'],
    autostart => 1
};

$config->{ifaces}->{'eth1.100'} = {
    type => 'vlan',
    mtu => 1400,
    method => 'manual',
    families => ['inet'],
    autostart => 1
};

$config->{ifaces}->{'vmbr4'} = {
    mtu => 1200,
    type => 'bridge',
    method => 'manual',
    families => ['inet'],
    bridge_stp => 'off',
    bridge_fd => 0,
    bridge_ports => 'bond0.100',
    autostart => 1
};

$config->{ifaces}->{'vmbr5'} = {
    mtu => 1100,
    type => 'bridge',
    method => 'manual',
    families => ['inet'],
    bridge_stp => 'off',
    bridge_fd => 0,
    bridge_ports => 'vmbr4.99',
    autostart => 1
};

$config->{ifaces}->{vmbr6} = {
    ovs_mtu => 1400,
    type => 'OVSBridge',
    ovs_ports => 'bond1 ovsintvlan',
    method => 'manual',
    families => ['inet'],
    autostart => 1
};

$config->{ifaces}->{bond1} = {
    ovs_mtu => 1300,
    type => 'OVSBond',
    ovs_bridge => 'vmbr6',
    ovs_bonds => 'eth4 eth5',
    ovs_options => 'bond_mode=active-backup',
    method => 'manual',
    families => ['inet'],
    autostart => 1
};

$config->{ifaces}->{ovsintvlan} = {
    ovs_mtu => 1300,
    type => 'OVSIntPort',
    ovs_bridge => 'vmbr6',
    ovs_options => 'tag=14',
    method => 'manual',
    families => ['inet'],
    autostart => 1
};

expect load('loopback') . <<"CHECK";
source-directory interfaces.d

iface eth0 inet manual

$eth1_part

auto eth2
iface eth2 inet manual

auto eth3
iface eth3 inet manual

auto eth4
iface eth4 inet manual

auto eth5
iface eth5 inet manual

auto eth1.100
iface eth1.100 inet manual
	mtu 1400

auto ovsintvlan
iface ovsintvlan inet manual
	ovs_type OVSIntPort
	ovs_bridge vmbr6
	ovs_mtu 1300
	ovs_options tag=14

$bond0_part

auto bond1
iface bond1 inet manual
	ovs_bonds eth4 eth5
	ovs_type OVSBond
	ovs_bridge vmbr6
	ovs_mtu 1300
	ovs_options bond_mode=active-backup

auto bond0.100
iface bond0.100 inet manual
	mtu 1300
	vlan-protocol 802.1ad

auto bond0.100.10
iface bond0.100.10 inet manual
	mtu 1300

$vmbr0_part

$vmbr123_part

auto vmbr4
iface vmbr4 inet manual
	bridge-ports bond0.100
	bridge-stp off
	bridge-fd 0
	mtu 1200

auto vmbr5
iface vmbr5 inet manual
	bridge-ports vmbr4.99
	bridge-stp off
	bridge-fd 0
	mtu 1100

auto vmbr6
iface vmbr6 inet manual
	ovs_type OVSBridge
	ovs_ports bond1 ovsintvlan
	ovs_mtu 1400

auto vmbr1.100
iface vmbr1.100 inet manual
	mtu 1300

$vxlan123_part

CHECK

#
# Now check the new config for idempotency:
#

save('if', w());
r(load('if'));
expect load('if');

#
# Check a brbase with an ipv6 address on eth1
#

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
	address $ip/$nm
	gateway $gw

iface eth2 inet manual

iface eth3 inet manual

iface eth4 inet manual

iface eth5 inet manual

auto vmbr0
iface vmbr0 inet static
	address 10.0.0.2/24
	gateway 10.0.0.1
	bridge-ports eth0
	bridge-stp off
	bridge-fd 0

CHECK

save('if', w());
r(load('if'));
expect load('if');

1;
