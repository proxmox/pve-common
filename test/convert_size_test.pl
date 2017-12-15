#!/usr/bin/perl

use lib '../src';
use strict;
use warnings;
use Data::Dumper;
use Test::More;

use PVE::Tools;

my $tests = [
    [
	1,           # input value
	'gb',        # from
	'kb',        # to
	undef,       # no_round_up
	1*1024*1024, # result
	undef,       # error string
    ],
    [ -1, 'gb', 'kb', undef, 1*1024*1024, "value '-1' is not a valid, positive number" ],
    [ 1.5, 'gb', 'kb', undef, 1.5*1024*1024 ],
    [  0.0005, 'gb', 'mb', undef, 1 ],
    [  0.0005, 'gb', 'mb', 1, 0 ],
    [ '.5', 'gb', 'kb', undef, .5*1024*1024 ],
    [ '1.', 'gb', 'kb', undef, 1.*1024*1024 ],
    [  0.5, 'mb', 'gb', undef, 1, ],
    [  0.5, 'mb', 'gb', 1, 0, ],
    [ '.', 'gb', 'kb', undef, 0, "value '.' is not a valid, positive number" ],
    [ '', 'gb', 'kb', undef, 0, "no value given" ],
    [ '1.1.', 'gb', 'kb', undef, 0, "value '1.1.' is not a valid, positive number" ],
    [ 500, 'kb', 'kb', undef, 500, ],
    [ 500000, 'b', 'kb', undef, 489, ],
    [ 500000, 'b', 'kb', 0, 489, ],
    [ 500000, 'b', 'kb', 1, 488, ],
    [ 128*1024 - 1, 'b', 'kb', 0, 128, ],
    [ 128*1024 - 1, 'b', 'kb', 1, 127, ],
    [ "abcdef", 'b', 'kb', 0, 0, "value 'abcdef' is not a valid, positive number" ],
    [ undef, 'b', 'kb', 0, 0, "no value given" ],
    [ 0, 'b', 'pb', 0, 0, ],
    [ 0, 'b', 'yb', 0, 0, "unknown 'from' and/or 'to' units (b => yb)"],
    [ 0, 'b', undef, 0, 0, "unknown 'from' and/or 'to' units (b => )"],
];

foreach my $test (@$tests) {
    my ($input, $from, $to, $no_round_up, $expect, $error) = @$test;

    my $result = eval { PVE::Tools::convert_size($input, $from, $to, $no_round_up); };
    my $err = $@;
    $input = $input // "";
    $from = $from // "";
    $to = $to // "";
    if ($error) {
	like($err, qr/^\Q$error\E/, "expected error for $input $from -> $to: $error");
    } else {
	my $round = $no_round_up ? 'floor' : 'ceil';
	is($result, $expect, "$input $from converts to $expect $to ($round)");
    }
};

done_testing();
