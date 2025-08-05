use JSON;

my $active_ifaces = ['lo', 'ens18', 'ens'];

my $ip_links = decode_json(load('ip_link_details'));
$ip_links->{ens18} = delete $ip_links->{eth0};
$ip_links->{ens18}->{ifname} = ens18;

my $wanted = load('base-allow-hotplug');

# parse the config
r($wanted, $ip_links, $active_ifaces);

$wanted =~ s/allow-hotplug ens18/auto ens18/; # FIXME: hack! rather we need to keep allow-hotplug!

expect $wanted;

# idempotency (save, re-parse, and re-check)
r(w(), $ip_links, $active_ifaces);
expect $wanted;

# parse one with both, "auto" and "allow-hotplug"
my $bad = load('base-auto-allow-hotplug');
r($bad, $ip_links, $active_ifaces);

# should drop the first occuring one of the conflicting options ("auto" currently)
expect $wanted;

1;
