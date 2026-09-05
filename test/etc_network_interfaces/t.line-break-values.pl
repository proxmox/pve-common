# A line break inside an option value would continue as new stanza lines in the written file, so
# the writer must refuse such values instead of writing them.

r(load('brbase'));

my $ifaces = $config->{ifaces};

my $must_fail = sub {
    my ($key, $value) = @_;

    my $backup = $ifaces->{vmbr0}->{$key};
    $ifaces->{vmbr0}->{$key} = $value;

    my $out = eval { w() };
    my $err = $@;
    die "line break in '$key' was written:\n$out" if defined($out);
    die "unexpected error for line break in '$key': $err"
        if $err !~ m/interface 'vmbr0' - option '\Q$key\E' contains a line break/;

    if (defined($backup)) {
        $ifaces->{vmbr0}->{$key} = $backup;
    } else {
        delete $ifaces->{vmbr0}->{$key};
    }
};

$must_fail->('ovs_options', "foo=bar\n\tpre-up /bin/sh -c 'id > /tmp/pwned'");
$must_fail->('bridge_vids', "2-10\n5");
$must_fail->('bridge_ports', "eth0\r\n\tpre-up /bin/true");
$must_fail->('address', "10.0.0.2/24\n");
$must_fail->('options', ["bridge-stp off\n\tpre-up /bin/true"]);

# comments are emitted one line each with a '#' prefix, so they may contain line breaks
$ifaces->{vmbr0}->{comments} = "first line\nsecond line\n";
my $out = w();
die "comment lines not written as comments:\n$out"
    if $out !~ m/^#first line\n#second line\n/m;
r($out);
die "comment did not round trip"
    if $config->{ifaces}->{vmbr0}->{comments} ne "first line\nsecond line\n";

1;
