my $ip = '10.0.0.2';
my $nm = '255.255.255.0';
my $gw = '10.0.0.1';
my $ip6 = 'fc05::1:2';
my $nm6 = '112';
my $gw6 = 'fc05::1:1';

r(load('base'));

new_iface('vmbr0', 'bridge', [{ family => 'inet' }], autostart => 1, bridge_ports => 'eth0');

expect load('base') . <<"EOF";
auto vmbr0
iface vmbr0 inet manual
	bridge-ports eth0
	bridge-stp off
	bridge-fd 0

EOF

# add an ip and disable previously enabled autostart
update_iface('vmbr0',
    [ { family => 'inet',
	address => $ip,
	netmask => $nm,
	gateway => $gw } ],
    autostart => 0);

expect load('base') . <<"EOF";
iface vmbr0 inet static
	address  $ip
	netmask  $nm
	gateway  $gw
	bridge-ports eth0
	bridge-stp off
	bridge-fd 0

EOF
save('with-ipv4', w());

update_iface('vmbr0',
    [ { family => 'inet6',
	address => $ip6,
	netmask => $nm6,
	gateway => $gw6 } ]);

expect load('with-ipv4') . <<"EOF";
iface vmbr0 inet6 static
	address  $ip6
	netmask  $nm6
	gateway  $gw6

EOF

# idempotency
save('idem', w());
r(load('idem'));
expect load('idem');

# delete vmbr0's inet
delete_iface('vmbr0', 'inet');

# bridge ports must now appear in the inet6 block
expect load('base') . <<"EOF";
iface vmbr0 inet6 static
	address  $ip6
	netmask  $nm6
	gateway  $gw6
	bridge-ports eth0
	bridge-stp off
	bridge-fd 0

EOF

# idempotency
save('idem', w());
r(load('idem'));
expect load('idem');

# delete vmbr0 completely
delete_iface('vmbr0');
expect load('base');

1;
