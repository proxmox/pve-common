save('proc_net_dev', <<'/proc/net/dev');
eth0:
eth1:
/proc/net/dev

# Check for dropped or duplicated options

my $ip = '192.168.0.2';
my $nm = '255.255.255.0';
my $gw = '192.168.0.1';
my $ip6 = 'fc05::2';
my $nm6 = '112';
my $gw6 = 'fc05::1';

# Load
my $cfg = load('base') . <<"CHECK";
iface eth1 inet manual

auto vmbr0
iface vmbr0 inet static
	address 10.0.0.2/24
	gateway 10.0.0.1
	bridge-ports eth0
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 2-4094

CHECK

r $cfg;
expect $cfg;

1;
