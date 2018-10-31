package PVE::CalendarEvent;

use strict;
use warnings;
use Data::Dumper;
use Time::Local;
use PVE::JSONSchema;
use PVE::Tools qw(trim);

# Note: This class implements a parser/utils for systemd like calendar exents
# Date specification is currently not implemented

my $dow_names = {
    sun => 0,
    mon => 1,
    tue => 2,
    wed => 3,
    thu => 4,
    fri => 5,
    sat => 6,
};

PVE::JSONSchema::register_format('pve-calendar-event', \&pve_verify_calendar_event);
sub pve_verify_calendar_event {
    my ($text, $noerr) = @_;

    eval { parse_calendar_event($text); };
    if (my $err = $@) {
	return undef if $noerr;
	die "invalid calendar event '$text' - $err\n";
    }
    return $text;
}

# The parser.
# returns a $calspec hash which can be passed to compute_next_event()
sub parse_calendar_event {
    my ($event) = @_;

    $event = trim($event);

    if ($event eq '') {
	die "unable to parse calendar event - event is empty\n";
    }

    my $parse_single_timespec = sub {
	my ($p, $max, $matchall_ref, $res_hash) = @_;

	if ($p =~ m/^((?:\*|[0-9]+))(?:\/([1-9][0-9]*))?$/) {
	    my ($start, $repetition) = ($1, $2);
	    if (defined($repetition)) {
		$repetition = int($repetition);
		$start = $start eq '*' ? 0 : int($start);
		die "value '$start' out of range\n" if $start >= $max;
		die "repetition '$repetition' out of range\n" if $repetition >= $max;
		while ($start < $max) {
		    $res_hash->{$start} = 1;
		    $start += $repetition;
		}
	    } else {
		if ($start eq '*') {
		    $$matchall_ref = 1;
		} else {
		    $start = int($start);
		    die "value '$start' out of range\n" if $start >= $max;
		    $res_hash->{$start} = 1;
		}
	    }
	} elsif ($p =~ m/^([0-9]+)\.\.([1-9][0-9]*)$/) {
	    my ($start, $end) = (int($1), int($2));
	    die "range start '$start' out of range\n" if $start >= $max;
	    die "range end '$end' out of range\n" if $end >= $max || $end < $start;
	    for (my $i = $start; $i <= $end; $i++) {
		$res_hash->{$i} = 1;
	    }
	} else {
	    die "unable to parse calendar event '$p'\n";
	}
    };

    my $h = undef;
    my $m = undef;

    my $matchall_minutes = 0;
    my $matchall_hours = 0;
    my $minutes_hash = {};
    my $hours_hash = {};

    my $dowsel = join('|', keys %$dow_names);

    my $dow_hash;

    my $parse_dowspec = sub {
	my ($p) = @_;

	if ($p =~ m/^($dowsel)$/i) {
	    $dow_hash->{$dow_names->{lc($1)}} = 1;
	} elsif ($p =~ m/^($dowsel)\.\.($dowsel)$/i) {
	    my $start = $dow_names->{lc($1)};
	    my $end = $dow_names->{lc($2)} || 7;
	    die "wrong order in range '$p'\n" if $end < $start;
	    for (my $i = $start; $i <= $end; $i++) {
		$dow_hash->{($i % 7)} = 1;
	    }
	} else {
	    die "unable to parse weekday specification '$p'\n";
	}
    };

    my @parts = split(/\s+/, $event);

    if ($parts[0] =~ m/$dowsel/i) {
	my $dow_spec = shift @parts;
	foreach my $p (split(',', $dow_spec)) {
	    $parse_dowspec->($p);
	}
    } else {
	$dow_hash = { 0 => 1, 1 => 1, 2 => 1, 3 => 1, 4 => 1, 5=> 1, 6 => 1 };
    }

    if (scalar(@parts) && $parts[0] =~ m/\-/) {
	my $date_spec = shift @parts;
	die "date specification not implemented";
    }

    my $time_spec = shift(@parts) // "00:00";
    my $chars = '[0-9*/.,]';

    if ($time_spec =~ m/^($chars+):($chars+)$/) {
	my ($p1, $p2) = ($1, $2);
	foreach my $p (split(',', $p1)) {
	    $parse_single_timespec->($p, 24, \$matchall_hours, $hours_hash);
	}
	foreach my $p (split(',', $p2)) {
	    $parse_single_timespec->($p, 60, \$matchall_minutes, $minutes_hash);
	}
    } elsif ($time_spec =~ m/^($chars)+$/) { # minutes only
	$matchall_hours = 1;
	foreach my $p (split(',', $time_spec)) {
	    $parse_single_timespec->($p, 60, \$matchall_minutes, $minutes_hash);
	}

    } else {
	die "unable to parse calendar event\n";
    }

    die "unable to parse calendar event - unused parts\n" if scalar(@parts);

    if ($matchall_hours) {
	$h = '*';
    } else {
	$h = [ sort { $a <=> $b } keys %$hours_hash ];
    }

    if ($matchall_minutes) {
	$m = '*';
    } else {
	$m = [ sort { $a <=> $b } keys %$minutes_hash ];
    }

    return { h => $h, m => $m, dow => [ sort keys %$dow_hash ]};
}

sub is_leap_year($) {
    return 0 if $_[0] % 4;
    return 1 if $_[0] % 100;
    return 0 if $_[0] % 400;
    return 1;
}

# mon = 0.. (Jan = 0)
sub days_in_month($$) {
    my ($mon, $year) = @_;
    return 28 + is_leap_year($year) if $mon == 1;
    return (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[$mon];
}

# day = 1..
# mon = 0.. (Jan = 0)
sub wrap_time($) {
    my ($time) = @_;
    my ($sec, $min, $hour, $day, $mon, $year, $wday) = @$time;

    use integer;
    if ($sec >= 60) {
	$min += $sec / 60;
	$sec %= 60;
    }

    if ($min >= 60) {
	$hour += $min / 60;
	$min %= 60;
    }

    if ($hour >= 24) {
	$day  += $hour / 24;
	$wday += $hour / 24;
	$hour %= 24;
    }

    # Translate to 0..($days_in_mon-1)
    --$day;
    while (1) {
	my $days_in_mon = days_in_month($mon % 12, $year);
	last if $day < $days_in_mon;
	# Wrap one month
	$day -= $days_in_mon;
	++$mon;
    }
    # Translate back to 1..$days_in_mon
    ++$day;

    if ($mon >= 12) {
	$year += $mon / 12;
	$mon %= 12;
    }

    $wday %= 7;
    return [$sec, $min, $hour, $day, $mon, $year, $wday];
}

# helper as we need to keep weekdays in sync
sub time_add_days($$) {
    my ($time, $inc) = @_;
    my ($sec, $min, $hour, $day, $mon, $year, $wday) = @$time;
    return wrap_time([$sec, $min, $hour, $day + $inc, $mon, $year, $wday + $inc]);
}

sub compute_next_event {
    my ($calspec, $last, $utc) = @_;

    my $hspec = $calspec->{h};
    my $mspec = $calspec->{m};
    my $dowspec = $calspec->{dow};

    $last += 60; # at least one minute later

    my $t = [$utc ? gmtime($last) : localtime($last)];
    $t->[0] = 0;     # we're not interested in seconds, actually
    $t->[5] += 1900; # real years for clarity

    outer: for (my $i = 0; $i < 1000; ++$i) {
	my $wday = $t->[6];
	foreach my $d (@$dowspec) {
	    goto this_wday if $d == $wday;
	    if ($d > $wday) {
		$t->[0] = $t->[1] = $t->[2] = 0; # sec = min = hour = 0
		$t = time_add_days($t, $d - $wday);
		next outer;
	    }
	}
	# Test next week:
	$t->[0] = $t->[1] = $t->[2] = 0; # sec = min = hour = 0
	$t = time_add_days($t, 7 - $wday);
	next outer;
    this_wday:

	goto this_hour if $hspec eq '*';
	my $hour = $t->[2];
	foreach my $h (@$hspec) {
	    goto this_hour if $h == $hour;
	    if ($h > $hour) {
		$t->[0] = $t->[1] = 0; # sec = min = 0
		$t->[2] = $h;          # hour = $h
		next outer;
	    }
	}
	# Test next day:
	$t->[0] = $t->[1] = $t->[2] = 0; # sec = min = hour = 0
	$t = time_add_days($t, 1);
	next outer;
    this_hour:

	goto this_min if $mspec eq '*';
	my $min = $t->[1];
	foreach my $m (@$mspec) {
	    goto this_min if $m == $min;
	    if ($m > $min) {
		$t->[0] = 0;  # sec = 0
		$t->[1] = $m; # min = $m
		next outer;
	    }
	}
	# Test next hour:
	$t->[0] = $t->[1] = 0; # sec = min = hour = 0
	$t->[2]++;
	$t = wrap_time($t);
	next outer;
    this_min:

	return $utc ? timegm(@$t) : timelocal(@$t);
    }

    die "unable to compute next calendar event\n";
}

1;
