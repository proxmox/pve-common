use JSON;
use Storable qw(dclone);

my $ip_links = decode_json(load('ip_link_details'));

for my $idx (1 .. 2) {
    my $entry = dclone($ip_links->{eth0});
    $entry->{ifname} = "eth$idx";

    $ip_links->{"eth$idx"} = $entry;
}

# other spellings are normalized, explicit values are kept
r(<<'EOF', $ip_links);
auto eth1
iface eth1 inet static
	address 192.0.2.10/24
	ip_forward yes

auto eth2
iface eth2 inet manual
	ip-forward off

EOF

die "ip-forward not parsed as boolean\n"
    if $config->{ifaces}->{eth1}->{'ip-forward'} ne '1'
    || $config->{ifaces}->{eth2}->{'ip-forward'} ne '0';

my $expected = <<'EOF';
auto eth1
iface eth1 inet static
	address 192.0.2.10/24
	ip-forward on

auto eth2
iface eth2 inet manual
	ip-forward off

EOF

expect(load('loopback') . $expected . "iface eth0 inet manual\n\n");

delete $config->{ifaces}->{eth1}->{'ip-forward'};
$expected =~ s/\tip-forward on\n//;
expect(load('loopback') . $expected . "iface eth0 inet manual\n\n");

# bridge ports are no L3 interfaces, ifupdown2 refuses ip-forward on them
r(<<'EOF', $ip_links);
iface eth1 inet manual
	ip-forward on

auto vmbr0
iface vmbr0 inet manual
	bridge-ports eth1
	bridge-stp off
	bridge-fd 0

EOF

eval { w() };
die "ip-forward on a bridge port was not rejected\n"
    if $@ !~ m/^bridge 'vmbr0' - port 'eth1' cannot have ip-forward set$/m;

# ifupdown2 uses the first value if it is set more than once
r(<<'EOF', $ip_links);
iface eth1 inet manual
	ip-forward off
	ip_forward on

EOF

die "ip-forward did not keep the first value\n" if $config->{ifaces}->{eth1}->{'ip-forward'} ne '0';

# ifupdown2 does not accept other values, so they are not interpreted
r(<<'EOF', $ip_links);
iface eth1 inet manual
	ip-forward true

EOF

die "unknown ip-forward value was interpreted\n"
    if defined($config->{ifaces}->{eth1}->{'ip-forward'});
expect(load('loopback')
    . "iface eth1 inet manual\n\tip-forward true\n\n"
    . "iface eth0 inet manual\n\niface eth2 inet manual\n\n");

1;
