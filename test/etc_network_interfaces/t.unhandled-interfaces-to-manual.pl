use JSON;
use Storable qw(dclone);

my $ip_links = decode_json(load('ip_link_details'));

for my $idx (1 .. 3) {
    my $entry = dclone($ip_links->{eth0});
    $entry->{ifname} = "eth$idx";

    $ip_links->{"eth$idx"} = $entry;
}

r('', $ip_links);

expect load('base') . <<'IFACES';
iface eth1 inet manual

iface eth2 inet manual

iface eth3 inet manual

IFACES

1;
