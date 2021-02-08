#!/usr/bin/perl

use strict;
use warnings;

use lib '../src';
use PVE::JSONSchema;
use PVE::CLIFormatter;

use Test::More;
use Test::MockModule;

my $valid_configids = [
	'aa', 'a0', 'a_', 'a-', 'a-a', 'a'x100, 'Aa', 'AA',
];
my $invalid_configids = [
	'a', 'a+', '1a', '_a', '-a', '+a', 'A',
];

my $noerr = 1; # easier to test
foreach my $id (@$valid_configids) {
    is(PVE::JSONSchema::pve_verify_configid($id, $noerr), $id, 'valid configid');
}
foreach my $id (@$invalid_configids) {
    is(PVE::JSONSchema::pve_verify_configid($id, $noerr), undef, 'invalid configid');
}

# test some string rendering
my $render_data = [
    ["timestamp", 0, undef, "1970-01-01 01:00:00"],
    ["timestamp", 1612776831, undef, "2021-02-08 10:33:51"],
    ["timestamp_gmt", 0, undef, "1970-01-01 00:00:00"],
    ["timestamp_gmt", 1612776831, undef, "2021-02-08 09:33:51"],
    ["duration", 0, undef, ""],
    ["duration", 40, undef, "40s"],
    ["duration", 60, undef, "1m"],
    ["duration", 110, undef, "1m 50s"],
    ["duration", 7*24*3829*2, undef, "2w 21h 22m 24s"],
    ["fraction_as_percentage", 0.412, undef, "41.20%"],
    ["bytes", 0, undef, "0.00 B"],
    ["bytes", 1023, 4, "1023.0000 B"],
    ["bytes", 1024, undef, "1.00 KiB"],
    ["bytes", 1024*1024*123 + 1024*300, 1, "123.3 MiB"],
    ["bytes", 1024*1024*1024*1024*4 + 1024*1024*2048*8, undef, "4.02 TiB"],
];

foreach my $data (@$render_data) {
    my ($renderer_name, $p1, $p2, $expected) = @$data;
    my $renderer = PVE::JSONSchema::get_renderer($renderer_name);
    my $actual = $renderer->($p1, $p2);
    is($actual, $expected, "string format '$renderer_name'");
}

done_testing();
