save('proc_net_dev', <<'/proc/net/dev');
eth0:
eth1:
/proc/net/dev

r(load('brbase'));

my $ip = '192.168.0.2';
my $nm = '255.255.255.0';
my $gw = '192.168.0.1';

$config->{ifaces}->{eth1} = {
    type => 'eth',
    method => 'static',
    address => $ip,
    netmask => $nm,
    gateway => $gw,
    families => ['inet'],
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
	bridge_ports eth0
	bridge_stp off
	bridge_fd 0

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
	bridge_ports eth0
	bridge_stp off
	bridge_fd 0

CHECK

save('if', w());
r(load('if'));
expect load('if');

1;
