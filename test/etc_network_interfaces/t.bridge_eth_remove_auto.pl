use strict;

# access to the current config
our $config;

# replace proc_net_dev with one with a bunch of interfaces
save('proc_net_dev', <<'/proc/net/dev');
eth0:
eth1:
/proc/net/dev

r('');
update_iface('eth0', [], autostart => 1);
update_iface('eth1', [], autostart => 1);
r(w());
die "autostart lost" if !$config->{ifaces}->{eth0}->{autostart};
die "autostart lost" if !$config->{ifaces}->{eth1}->{autostart};
new_iface("vmbr0", 'bridge', [{ family => 'inet' }], bridge_ports => 'eth0');
new_iface("vmbr1", 'OVSBridge', [{ family => 'inet' }], ovs_ports => 'eth1');
r(w());
die "autostart not removed for linux bridge port" if $config->{ifaces}->{eth0}->{autostart};
die "autostart not removed for ovs bridge port" if $config->{ifaces}->{eth1}->{autostart};

1;
