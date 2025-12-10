package PVE::IPRoute2;

use v5.36;

use JSON qw(decode_json);
use PVE::Tools qw(run_command);

# Some simple wrappers around the iproute2 `ip` utillity.

# TODO: revisit PVE::Network et al. for some other potential canidates which are mostly thin
# wrappers around ip with some (relatively minimal) data juggling before/after.

sub ip_link_details() {
    my $link_json = '';

    run_command(
        ['ip', '-details', '-json', 'link', 'show'],
        outfunc => sub {
            $link_json .= shift;
        },
    );

    my $links = decode_json($link_json);
    my %ip_links = map { $_->{ifname} => $_ } $links->@*;

    return \%ip_links;
}

sub ip_link_is_physical($ip_link) {
    # ether alone isn't enough, as virtual interfaces can also have link_type 'ether'
    return $ip_link->{link_type} eq 'ether'
        && (!defined($ip_link->{linkinfo}) || !defined($ip_link->{linkinfo}->{info_kind}));
}

sub ip_link_is_bridge($ip_link) {
    return
        defined($ip_link->{linkinfo})
        && defined($ip_link->{linkinfo}->{info_kind})
        && $ip_link->{linkinfo}->{info_kind} eq 'bridge';
}

sub bridge_is_vlan_aware($ip_link) {
    if (!ip_link_is_bridge($ip_link)) {
        warn "passed link that isn't a bridge to bridge_is_vlan_aware";
        return 0;
    }

    return
        defined($ip_link->{linkinfo}->{info_data})
        && defined($ip_link->{linkinfo}->{info_data}->{vlan_filtering})
        && $ip_link->{linkinfo}->{info_data}->{vlan_filtering} == 1;
}

sub ip_link_is_bridge_member($ip_link) {
    return
        defined($ip_link->{linkinfo})
        && defined($ip_link->{linkinfo}->{info_slave_kind})
        && $ip_link->{linkinfo}->{info_slave_kind} eq "bridge";
}

sub get_physical_bridge_ports($bridge, $ip_links = undef) {
    $ip_links = ip_link_details() if !defined($ip_links);

    if (!ip_link_is_bridge($ip_links->{$bridge})) {
        warn "passed link that isn't a bridge to get_physical_bridge_ports";
        return ();
    }

    return grep {
        ip_link_is_physical($ip_links->{$_}) && $ip_links->{$_}->{master} eq $bridge
    } keys $ip_links->%*;
}

sub altname_mapping($ip_links) {
    $ip_links = ip_link_details() if !defined($ip_links);

    my $altnames = {};

    for my $iface_name (keys $ip_links->%*) {
        my $iface = $ip_links->{$iface_name};

        next if !$iface->{altnames};

        for my $altname ($iface->{altnames}->@*) {
            $altnames->{$altname} = $iface_name;
        }
    }

    return $altnames;
}

sub get_vlan_information() {
    my $bridge_output = '';

    run_command(
        [
            'bridge', '-compressvlans', '-json', 'vlan', 'show',
        ],
        outfunc => sub {
            $bridge_output .= shift;
        },
    );

    my $data = decode_json($bridge_output);
    my %vlan_information = map { $_->{ifname} => $_ } $data->@*;

    return \%vlan_information;
}

1;
