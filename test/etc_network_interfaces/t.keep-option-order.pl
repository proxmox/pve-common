#
# Order of option lines between interfaces should be preserved:
# eth0 is unconfigured and will thus end up at the end as 'manual'
#
my $ordered = <<'ORDERED';
source /etc/network/config1

iface eth1 inet manual

source-directory /etc/network/interfaces.d

iface eth2 inet manual

iface eth3 inet manual

ORDERED

r(
    "$ordered", <<'/proc/net/dev',
eth0:
eth1:
eth2:
eth3:
/proc/net/dev
);

expect(load('loopback') . $ordered . "iface eth0 inet manual\n\n");

1;
