save('proc_net_dev', <<'/proc/net/dev');
eth0:
eth1:
/proc/net/dev

my $ip = '192.168.0.2/24';
my $gw = '192.168.0.1';
my $ip6 = 'fc05::2/112';
my $gw6 = 'fc05::1';

# Load
r(load('brbase'));

# Create eth1
$config->{ifaces}->{eth1} = {
    type => 'eth',
    method => 'static',
    address => $ip,
    gateway => $gw,
    families => ['inet'],
    autostart => 1,
};

# Check
expect load('loopback') . <<"CHECK";
source-directory interfaces.d

iface eth0 inet manual

auto eth1
iface eth1 inet static
	address $ip
	gateway $gw

auto vmbr0
iface vmbr0 inet static
	address 10.0.0.2/24
	gateway 10.0.0.1
	bridge-ports eth0
	bridge-stp off
	bridge-fd 0

CHECK

# Reload then modify
save('ipv4', w());
r(load('ipv4'));
expect load('ipv4');

$config->{ifaces}->{eth1}->{ $_->[0] } = $_->[1]
    foreach (
        [method6 => 'static'],
        [address6 => $ip6],
        [netmask6 => $nm6],
        [gateway6 => $gw6],
        [families => ['inet', 'inet6']],
    );

# Check
my $final = load('loopback') . <<"CHECK";
source-directory interfaces.d

iface eth0 inet manual

auto eth1
iface eth1 inet static
	address $ip
	gateway $gw

iface eth1 inet6 static
	address $ip6
	gateway $gw6

auto vmbr0
iface vmbr0 inet static
	address 10.0.0.2/24
	gateway 10.0.0.1
	bridge-ports eth0
	bridge-stp off
	bridge-fd 0

CHECK
expect $final;

save('both', w());
r(load('both'));
expect load('both');

# Reload ipv4 and replace instead of modifying
r(load('ipv4'));

$config->{ifaces}->{eth1} = {
    type => 'eth',
    method => 'static',
    address => $ip,
    netmask => $nm,
    gateway => $gw,
    method6 => 'static',
    address6 => $ip6,
    netmask6 => $nm6,
    gateway6 => $gw6,
    families => ['inet', 'inet6'],
    autostart => 1,
};
expect $final;
r(w());
expect $final;

1;
