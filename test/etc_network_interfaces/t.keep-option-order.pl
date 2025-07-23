use JSON;
use Storable qw(dclone);

my $ip_links = decode_json(load('ip_link_details'));

for my $idx (1 .. 3) {
    my $entry = dclone($ip_links->{eth0});
    $entry->{ifname} = "eth$idx";

    $ip_links->{"eth$idx"} = $entry;
}

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

r($ordered, $ip_links);

expect(load('loopback') . $ordered . "iface eth0 inet manual\n\n");

1;
