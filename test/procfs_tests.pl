#!/usr/bin/perl

use strict;
use warnings;

use lib '../src';

use Test::More;
use Test::MockModule;

use PVE::Tools;
use PVE::ProcFSTools;

# the proc "state"
my $proc = {
    version => '',
};

my $pve_common_tools;
$pve_common_tools = Test::MockModule->new('PVE::Tools');
$pve_common_tools->mock(
    file_read_firstline => sub {
	my ($filename) = @_;

	$filename =~ s!^/proc/!!;

	my $res = $proc->{$filename};

	if (ref($res) eq 'CODE') {
	    $res = $res->();
	}

	chomp $res;
	return $res;
    },
);


# version tests

my @kernel_versions = (
{
    version => 'Linux version 5.3.10-1-pve (build@pve) (gcc version 8.3.0 (Debian 8.3.0-6)) #1 SMP PVE 5.3.10-1 (Thu, 14 Nov 2019 10:43:13 +0100)',
    expect => [5, 3, 10, '1-pve', '5.3.10-1-pve'],
},
{
    version => 'Linux version 5.0.21-5-pve (build@pve) (gcc version 8.3.0 (Debian 8.3.0-6)) #1 SMP PVE 5.0.21-10 (Wed, 13 Nov 2019 08:27:10 +0100)',
    expect => [5, 0, 21, '5-pve', '5.0.21-5-pve'],
},
{
    version => 'Linux version 5.0.21+ (build@pve) (gcc version 8.3.0 (Debian 8.3.0-6)) #27 SMP Tue Nov 12 10:30:36 CET 2019',
    expect => [5, 0, 21, '+', '5.0.21+'],
},
{
    version => 'Linu$ version 2 (build@pve) (gcc version 8.3.0 (Debian 8.3.0-6)) #27 SMP Tue Nov 12 10:30:36 CET 2019',
    expect => [0, 0, 0, '', ''],
},
);

subtest 'test kernel_version parser' => sub {
    for my $test (@kernel_versions) {
	$proc->{version} = $test->{version};

	my $res = [ PVE::ProcFSTools::kernel_version() ];

	is_deeply($res, $test->{expect}, "got version <". $res->[4] ."> same as expected");
    }
};


done_testing();
