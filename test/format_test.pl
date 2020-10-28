#!/usr/bin/perl

use strict;
use warnings;

use lib '../src';
use PVE::JSONSchema;

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

done_testing();