my $active_ifaces = ['lo', 'ens18', 'ens'];
my $proc_net = load('proc_net_dev');
$proc_net =~ s/eth0/ens18/;

my $wanted = load('base-allow-hotplug');

# parse the config
r($wanted, $proc_net, $active_ifaces);

$wanted =~ s/allow-hotplug ens18/auto ens18/; # FIXME: hack! rather we need to keep allow-hotplug!

expect $wanted;

# idempotency (save, re-parse, and re-check)
r(w(), $proc_net, $active_ifaces);
expect $wanted;

# parse one with both, "auto" and "allow-hotplug"
my $bad = load('base-auto-allow-hotplug');
r($bad, $proc_net, $active_ifaces);

# should drop the first occuring one of the conflicting options ("auto" currently)
expect $wanted;

1;
