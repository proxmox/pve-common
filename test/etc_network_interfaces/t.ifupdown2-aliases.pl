use JSON;
use Storable qw(dclone);

my $ip_links = decode_json(load('ip_link_details'));

for my $idx (1 .. 2) {
    my $entry = dclone($ip_links->{eth0});
    $entry->{ifname} = "eth$idx";

    $ip_links->{"eth$idx"} = $entry;
}

my $base = load('loopback');

# ifupdown2 accepts 'bond-ports' for 'bond-slaves' and 'bridge-trunk' for 'bridge-vids'
r($base . <<'IFACES', $ip_links);
iface eth0 inet manual

iface eth1 inet manual

iface eth2 inet manual

auto bond0
iface bond0 inet manual
	bond-ports eth1 eth2
	bond-miimon 100
	bond-mode active-backup

auto vmbr0
iface vmbr0 inet static
	address 10.0.0.2/24
	gateway 10.0.0.1
	bridge-ports bond0
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-trunk 2-100

IFACES

expect $base . <<'IFACES';
iface eth0 inet manual

auto eth1
iface eth1 inet manual

auto eth2
iface eth2 inet manual

auto bond0
iface bond0 inet manual
	bond-slaves eth1 eth2
	bond-miimon 100
	bond-mode active-backup

auto vmbr0
iface vmbr0 inet static
	address 10.0.0.2/24
	gateway 10.0.0.1
	bridge-ports bond0
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 2-100

IFACES

1;
