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

1;
