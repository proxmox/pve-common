my $ip = '10.0.0.2/24';
my $gw = '10.0.0.1';
my $ip6 = 'fc05::1:2/112';
my $gw6 = 'fc05::1:1';

r(load('base') . <<"EOF");
auto vmbr1
iface vmbr1
	address 1.2.3.4/24
	address fccc::a:1/64
	gateway 1.2.3.1
	gateway fccc::1
	bridge-ports eth0
	bridge-stp off
	bridge-fd 0
# Comment

EOF

my $run = 'first';
my $ifaces = $config->{ifaces};

my $ck = sub {
    my ($i, $v, $e) = @_;
    $ifaces->{$i}->{$v} eq $e
	or die "$run run: $i variable $v: got \"$ifaces->{$i}->{$v}\", expected: $e\n";
};

my $check_config = sub {
    $ck->('vmbr1', type => 'bridge');
    $ck->('vmbr1', cidr => '1.2.3.4/24');
    $ck->('vmbr1', gateway => '1.2.3.1');
    $ck->('vmbr1', cidr6 => 'fccc::a:1/64');
    $ck->('vmbr1', gateway6 => 'fccc::1');
};

$check_config->();

# idempotency
save('idem', w());
r(load('idem'));
expect load('idem');

$run = 'second';
$check_config->();

1;
