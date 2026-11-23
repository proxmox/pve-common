use JSON;
use Storable qw(dclone);

my $ip_links = decode_json(load('ip_link_details'));

for my $idx (1 .. 3) {
    my $entry = dclone($ip_links->{eth0});
    $entry->{ifname} = "eth$idx";

    $ip_links->{"eth$idx"} = $entry;
}

# Valid ovs_options are allowed on OVS bridges, promoted OVS ports, internal ports, and OVS bonds.
r('', $ip_links);

new_iface(
    'vmbr1',
    'OVSBridge',
    [{ family => 'inet' }],
    autostart => 1,
    ovs_ports => 'eth1 ovsint0 bond0',
    ovs_options => 'stp_enable=true',
);
update_iface('eth1', [], ovs_options => 'trunks=10,20');
new_iface(
    'ovsint0',
    'OVSIntPort',
    [{ family => 'inet', address => '192.0.2.20/24' }],
    ovs_bridge => 'vmbr1',
    ovs_options => 'vlan_mode=native-untagged',
);
new_iface(
    'bond0',
    'OVSBond',
    [{ family => 'inet' }],
    ovs_bridge => 'vmbr1',
    ovs_bonds => 'eth2 eth3',
    ovs_options => 'other_config:lacp-time=fast',
);

my $ovs_out = w();
die "OVSBridge ovs_options not written:\n$ovs_out"
    if $ovs_out !~ m/^\tovs_options stp_enable=true$/m;
die "OVSPort ovs_options not written:\n$ovs_out"
    if $ovs_out !~ m/^\tovs_options trunks=10,20$/m;
die "OVSIntPort ovs_options not written:\n$ovs_out"
    if $ovs_out !~ m/^\tovs_options vlan_mode=native-untagged$/m;
die "OVSBond ovs_options not written:\n$ovs_out"
    if $ovs_out !~ m/^\tovs_options .*other_config:lacp-time=fast/m;

r($ovs_out, $ip_links);
die "OVSBridge ovs_options did not round trip\n"
    if ($config->{ifaces}->{vmbr1}->{ovs_options} // '') ne 'stp_enable=true';
die "OVSPort ovs_options did not round trip\n"
    if ($config->{ifaces}->{eth1}->{ovs_options} // '') ne 'trunks=10,20';
die "OVSIntPort ovs_options did not round trip\n"
    if ($config->{ifaces}->{ovsint0}->{ovs_options} // '') ne 'vlan_mode=native-untagged';
die "OVSBond ovs_options did not round trip\n"
    if ($config->{ifaces}->{bond0}->{ovs_options} // '') ne 'other_config:lacp-time=fast';

# Stanzas parsed as 'unknown' that still have ovs_type set (e.g. OVSTunnel) keep their ovs_options.
r(<<'EOF', $ip_links);
auto vmbr1
iface vmbr1 inet manual
	ovs_type OVSBridge

iface gre0 inet manual
	ovs_type OVSTunnel
	ovs_bridge vmbr1
	ovs_tunnel_type gre
	ovs_tunnel_options options:remote_ip=198.51.100.2
	ovs_options tos=inherit

EOF

die "expected OVSTunnel to parse as unknown type\n"
    if $config->{ifaces}->{gre0}->{type} ne 'unknown';
die "expected OVSTunnel to keep ovs_type\n"
    if ($config->{ifaces}->{gre0}->{ovs_type} // '') ne 'OVSTunnel';

my $tunnel_out = w();
die "OVSTunnel ovs_options not written:\n$tunnel_out"
    if $tunnel_out !~ m/^\tovs_options tos=inherit$/m;

r($tunnel_out, $ip_links);
die "OVSTunnel ovs_options did not round trip\n"
    if ($config->{ifaces}->{gre0}->{ovs_options} // '') ne 'tos=inherit';

# Empty or whitespace-only ovs_options are silently dropped on both OVS and non-OVS interfaces.
r(load('brbase'), $ip_links);
new_iface('vmbr1', 'OVSBridge', [{ family => 'inet' }], autostart => 1, ovs_options => '   ');
$config->{ifaces}->{eth0}->{ovs_options} = '';
$config->{ifaces}->{vmbr0}->{ovs_options} = "   \t ";

my $empty_out = w();
die "empty/whitespace-only ovs_options was written:\n$empty_out"
    if $empty_out =~ m/ovs_options/;

my $must_fail = sub {
    my ($iface, $value, $expected_err) = @_;

    my $ifaces = $config->{ifaces};
    my $backup = $ifaces->{$iface}->{ovs_options};
    $ifaces->{$iface}->{ovs_options} = $value;

    my $out = eval { w() };
    my $err = $@;
    die "invalid ovs_options '$value' on '$iface' was written:\n$out" if defined($out);
    die "unexpected error for '$iface' ('$value'): $err"
        if $err !~ $expected_err;

    if (defined($backup)) {
        $ifaces->{$iface}->{ovs_options} = $backup;
    } else {
        delete $ifaces->{$iface}->{ovs_options};
    }
};

# Non-empty ovs_options must be rejected on non-OVS interfaces.
$must_fail->('eth0', 'tag=10', qr/^iface 'eth0' - ovs_options is only allowed on OVS interfaces$/m);
$must_fail->(
    'vmbr0',
    'tag=10',
    qr/^iface 'vmbr0' - ovs_options is only allowed on OVS interfaces$/m,
);

# Mako template opening tags must be rejected in ovs_options.
$must_fail->(
    'vmbr1',
    '<% import os %>',
    qr/^iface 'vmbr1' - ovs_options must not contain Mako template tags$/m,
);
$must_fail->(
    'vmbr1',
    'tag=${1+1}',
    qr/^iface 'vmbr1' - ovs_options must not contain Mako template tags$/m,
);

# Opaque options (e.g. ovs_extra / post-up using ${IFACE}) and pre-existing comments still work.
$config->{ifaces}->{vmbr1}->{options} = [
    'ovs_extra set bridge ${IFACE} other-config:hwaddr=00:59:cf:9c:84:3a',
];
$config->{ifaces}->{vmbr1}->{comments} = "existing \${var} and <% tag %> comment\n";
$config->{ifaces}->{vmbr0}->{options} = ['post-up ip link set ${IFACE} mtu 1500'];

my $mixed_out = w();
die "opaque ovs_extra option not written:\n$mixed_out"
    if $mixed_out !~ m/^\tovs_extra set bridge \$\{IFACE\} other-config:hwaddr=00:59:cf:9c:84:3a$/m;
die "opaque post-up option not written:\n$mixed_out"
    if $mixed_out !~ m/^\tpost-up ip link set \$\{IFACE\} mtu 1500$/m;
die "comment with template-like text not written:\n$mixed_out"
    if $mixed_out !~ m/^#existing \$\{var\} and <% tag %> comment$/m;

r($mixed_out, $ip_links);
die "opaque ovs_extra option did not round trip\n"
    if ($config->{ifaces}->{vmbr1}->{options}->[0] // '') ne
    'ovs_extra set bridge ${IFACE} other-config:hwaddr=00:59:cf:9c:84:3a';
die "comment with template-like text did not round trip\n"
    if ($config->{ifaces}->{vmbr1}->{comments} // '') ne "existing \${var} and <% tag %> comment\n";

1;
