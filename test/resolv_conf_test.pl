#!/usr/bin/perl

use v5.36;

use lib '../src';

use File::Temp;
use Test::More;

use PVE::INotify;

my $tests = [
    {
        name => 'single search domain',
        input => "search example.com\nnameserver 192.0.2.1\n",
        first => { search => 'example.com', dns1 => '192.0.2.1' },
        list => { search => 'example.com', dns1 => '192.0.2.1' },
    },
    {
        name => 'multiple search domains',
        input => "search a.example b.example c.example\nnameserver 192.0.2.1\n",
        first => { search => 'a.example', dns1 => '192.0.2.1' },
        list => { search => 'a.example b.example c.example', dns1 => '192.0.2.1' },
    },
    {
        name => 'multiple search domains with extra whitespace',
        input => "search\ta.example   b.example \t\nnameserver 192.0.2.1\n",
        first => { search => 'a.example', dns1 => '192.0.2.1' },
        list => { search => 'a.example b.example', dns1 => '192.0.2.1' },
    },
    {
        name => 'domain directive',
        input => "domain example.com\nnameserver 192.0.2.1\n",
        first => { search => 'example.com', dns1 => '192.0.2.1' },
        list => { search => 'example.com', dns1 => '192.0.2.1' },
    },
    {
        name => 'domain directive with trailing words',
        input => "domain a.example b.example\nnameserver 192.0.2.1\n",
        first => { search => 'a.example', dns1 => '192.0.2.1' },
        list => { search => 'a.example', dns1 => '192.0.2.1' },
    },
    {
        name => 'last of search and domain wins',
        input => "search a.example b.example\ndomain c.example d.example\n",
        first => { search => 'c.example' },
        list => { search => 'c.example' },
    },
    {
        name => 'only the first three name servers',
        input => "nameserver 192.0.2.1\nnameserver 192.0.2.2\n"
            . "nameserver 2001:db8::1\nnameserver 192.0.2.4\n",
        first => { dns1 => '192.0.2.1', dns2 => '192.0.2.2', dns3 => '2001:db8::1' },
        list => { dns1 => '192.0.2.1', dns2 => '192.0.2.2', dns3 => '2001:db8::1' },
    },
];

for my $test ($tests->@*) {
    open(my $fh, '<', \$test->{input}) or die "failed to open in-memory file - $!\n";
    my $res = PVE::INotify::read_etc_resolv_conf('/etc/resolv.conf', $fh);
    is_deeply($res, $test->{first}, "first search domain: $test->{name}");

    my $tmp = File::Temp->new();
    print $tmp $test->{input};
    close($tmp);
    $res = PVE::INotify::read_resolv_conf_with_search_list($tmp->filename);
    is_deeply($res, $test->{list}, "search list: $test->{name}");
}

is(
    PVE::INotify::read_resolv_conf_with_search_list('/nonexistent/resolv.conf'),
    undef,
    'search list: missing file',
);

{
    my $input = "search old.example\nnameserver 192.0.2.1\noptions rotate\n";
    open(my $fh, '<', \$input) or die "failed to open in-memory file - $!\n";
    my $data = PVE::INotify::update_etc_resolv_conf(
        '/etc/resolv.conf',
        $fh,
        { search => 'a.example b.example', dns1 => '192.0.2.2' },
    );
    is(
        $data,
        "search a.example b.example\nnameserver 192.0.2.2\noptions rotate\n",
        'update: write multiple search domains',
    );

    my $tmp = File::Temp->new();
    print $tmp $data;
    close($tmp);
    my $res = PVE::INotify::read_resolv_conf_with_search_list($tmp->filename);
    is($res->{search}, 'a.example b.example', 'update: read back multiple search domains');
}

done_testing();
