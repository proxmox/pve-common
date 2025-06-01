#!/usr/bin/perl

use lib '../src';

use strict;
use warnings;

use Test::More;
use PVE::Tools;

my $tests = [
    {
        name => 'both undef',
        a => undef,
        b => undef,
        expected => 1,
    },
    {
        name => 'empty string',
        a => '',
        b => '',
        expected => 1,
    },
    {
        name => 'empty string and undef',
        a => '',
        b => undef,
        expected => 0,
    },
    {
        name => '0 and undef',
        a => 0,
        b => undef,
        expected => 0,
    },
    {
        name => 'equal strings',
        a => 'test',
        b => 'test',
        expected => 1,
    },
    {
        name => 'unequal strings',
        a => 'test',
        b => 'tost',
        expected => 0,
    },
    {
        name => 'equal numerics',
        a => 42,
        b => 42,
        expected => 1,
    },
    {
        name => 'unequal numerics',
        a => 42,
        b => 420,
        expected => 0,
    },
    {
        name => 'equal arrays',
        a => ['foo', 'bar'],
        b => ['foo', 'bar'],
        expected => 1,
    },
    {
        name => 'equal empty arrays',
        a => [],
        b => [],
        expected => 1,
    },
    {
        name => 'unequal arrays',
        a => ['foo', 'bar'],
        b => ['bar', 'foo'],
        expected => 0,
    },
    {
        name => 'equal empty hashes',
        a => {},
        b => {},
        expected => 1,
    },
    {
        name => 'equal hashes',
        a => { foo => 'bar' },
        b => { foo => 'bar' },
        expected => 1,
    },
    {
        name => 'unequal hashes',
        a => { foo => 'bar' },
        b => { bar => 'foo' },
        expected => 0,
    },
    {
        name => 'equal nested hashes',
        a => {
            foo => 'bar',
            bar => 1,
            list => ['foo', 'bar'],
            properties => {
                baz => 'boo',
            },
        },
        b => {
            foo => 'bar',
            bar => 1,
            list => ['foo', 'bar'],
            properties => {
                baz => 'boo',
            },
        },
        expected => 1,
    },
    {
        name => 'unequal nested hashes',
        a => {
            foo => 'bar',
            bar => 1,
            list => ['foo', 'bar'],
            properties => {
                baz => 'boo',
            },
        },
        b => {
            foo => 'bar',
            bar => 1,
            list => ['foo', 'bar'],
            properties => {
                baz => undef,
            },
        },
        expected => 0,
    },
];

for my $test ($tests->@*) {
    is(PVE::Tools::is_deeply($test->{a}, $test->{b}), $test->{expected}, $test->{name});
}

done_testing();
