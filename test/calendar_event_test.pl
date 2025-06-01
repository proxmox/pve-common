#!/usr/bin/perl

use lib '../src';
use strict;
use warnings;
use POSIX ();
use Data::Dumper;
use Time::Local;
use Test::More;

use PVE::CalendarEvent;

# Time tests should run in a controlled setting
$ENV{TZ} = 'UTC';
POSIX::tzset();

my $alldays = [0, 1, 2, 3, 4, 5, 6];
my $tests = [
    [
        '*', undef, [
            [0, 60], [30, 60], [59, 60], [60, 120],
        ],
    ],
    [
        '*/10', undef, [
            [0, 600], [599, 600], [600, 1200], [50 * 60, 60 * 60],
        ],
    ],
    [
        '*/12:0', undef, [
            [10, 43200], [13 * 3600, 24 * 3600],
        ],
    ],
    [
        '1/12:0/15',
        undef,
        [
            [0, 3600],
            [3600, 3600 + 15 * 60],
            [3600 + 16 * 60, 3600 + 30 * 60],
            [3600 + 30 * 60, 3600 + 45 * 60],
            [3600 + 45 * 60, 3600 + 12 * 3600],
            [13 * 3600 + 1, 13 * 3600 + 15 * 60],
            [13 * 3600 + 15 * 60, 13 * 3600 + 30 * 60],
            [13 * 3600 + 30 * 60, 13 * 3600 + 45 * 60],
            [13 * 3600 + 45 * 60, 25 * 3600],
        ],
    ],
    [
        '1,4,6', undef, [
            [0, 60], [60, 4 * 60], [4 * 60 + 60, 6 * 60], [6 * 60, 3600 + 60],
        ],
    ],
    [
        '0..3', undef,
    ],
    [
        '23..23:0..3', undef,
    ],
    [
        'Mon',
        undef,
        [
            [0, 4 * 86400], # Note: Epoch 0 is Thursday, 1. January 1970
            [4 * 86400, 11 * 86400],
            [11 * 86400, 18 * 86400],
        ],
    ],
    [
        'sat..sun',
        undef,
        [
            [0, 2 * 86400], [2 * 86400, 3 * 86400], [3 * 86400, 9 * 86400],
        ],
    ],
    [
        'sun..sat',
        undef,
    ],
    [
        'Fri..Mon',
        { error => "wrong order in range 'Fri..Mon'" },
    ],
    [
        'wed,mon..tue,fri',
        undef,
    ],
    [
        'mon */15',
        undef,
    ],
    [
        '22/1:0',
        undef,
        [
            [0, 22 * 60 * 60],
            [22 * 60 * 60, 23 * 60 * 60],
            [22 * 60 * 60 + 59 * 60, 23 * 60 * 60],
        ],
    ],
    [
        '*/2:*',
        undef,
        [
            [0, 60], [60 * 60, 2 * 60 * 60], [2 * 60 * 60, 2 * 60 * 60 + 60],
        ],
    ],
    [
        '20..22:*/30',
        undef,
        [
            [0, 20 * 60 * 60],
            [20 * 60 * 60, 20 * 60 * 60 + 30 * 60],
            [22 * 60 * 60 + 30 * 60, 44 * 60 * 60],
        ],
    ],
    [
        '61',
        { error => "value '61' out of range" },
    ],
    [
        '*/61',
        { error => "repetition '61' out of range" },
    ],
    [
        '0..80',
        { error => "range end '80' out of range" },
    ],
    [
        ' mon 0 0 0',
        { error => "unable to parse calendar event - unused parts" },
    ],
    [
        '',
        { error => "unable to parse calendar event - event is empty" },
    ],
    [
        ' mon 0 0',
        { error => "unable to parse calendar event - unused parts" },
    ],
    [
        '0,1,3..5',
        undef,
        [
            [0, 60], [60, 3 * 60], [5 * 60, 60 * 60],
        ],
    ],
    [
        '2,4:0,1,3..5',
        undef,
        [
            [0, 2 * 60 * 60],
            [2 * 60 * 60 + 60, 2 * 60 * 60 + 3 * 60],
            [2 * 60 * 60 + 5 * 60, 4 * 60 * 60],
        ],
    ],
];

foreach my $test (@$tests) {
    my ($t, $expect, $nextsync) = @$test;

    $expect //= {};

    my $timespec;
    eval { $timespec = PVE::CalendarEvent::parse_calendar_event($t); };
    my $err = $@;

    if ($expect->{error}) {
        chomp $err if $err;
        ok(defined($err) == defined($expect->{error}), "parsing '$t' failed expectedly");
        die "unable to execute nextsync tests" if $nextsync;
    }

    next if !$nextsync;

    foreach my $nt (@$nextsync) {
        my ($last, $expect_next) = @$nt;
        my $msg = "next event '$t' $last => ${expect_next}";
        $timespec->{utc} = 1;
        my $next = PVE::CalendarEvent::compute_next_event($timespec, $last);
        is($next, $expect_next, $msg);
    }
}

sub tztest {
    my ($calspec, $last) = @_;
    my $spec = PVE::CalendarEvent::parse_calendar_event($calspec);
    return PVE::CalendarEvent::compute_next_event($spec, $last);
}

# Test loop termination at CEST/CET switch (cannot happen here in UTC)
is(tztest('mon..fri', timelocal(0, 0, 0, 28, 9, 2018)), timelocal(0, 0, 0, 29, 9, 2018));
is(tztest('mon..fri UTC', timelocal(0, 0, 0, 28, 9, 2018)), timelocal(0, 0, 0, 29, 9, 2018));

# Now in the affected time zone
$ENV{TZ} = ':Europe/Vienna';
POSIX::tzset();
is(tztest('mon..fri', timelocal(0, 0, 0, 28, 9, 2018)), timelocal(0, 0, 0, 29, 9, 2018));
# Specifically requesting UTC in the calendar spec means the resulting output
# time as seen locally (timelocal() as opposed to timegm()) is shifted by 1
# hour.
is(tztest('mon..fri UTC', timelocal(0, 0, 0, 28, 9, 2018)), timelocal(0, 0, 1, 29, 9, 2018));
$ENV{TZ} = 'UTC';
POSIX::tzset();

done_testing();
