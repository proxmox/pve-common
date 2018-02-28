package PVE::CalendarEvent;

use strict;
use warnings;
use Data::Dumper;
use Time::Local;
use PVE::JSONSchema;
use PVE::Tools qw(trim);

# Note: This class implements a parser/utils for systemd like calender exents
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

sub compute_next_event {
    my ($calspec, $last, $utc) = @_;

    my $hspec = $calspec->{h};
    my $mspec = $calspec->{m};
    my $dowspec = $calspec->{dow};

    $last += 60; # at least one minute later

    while (1) {

	my ($min, $hour, $mday, $mon, $year, $wday);
	my $startofday;

	if ($utc) {
	    (undef, $min, $hour, $mday, $mon, $year, $wday) = gmtime($last);
	    # gmtime and timegm interpret two-digit years differently
	    $year += 1900;
	    $startofday = timegm(0, 0, 0, $mday, $mon, $year);
	} else {
	    (undef, $min, $hour, $mday, $mon, $year, $wday) = localtime($last);
	    # localtime and timelocal interpret two-digit years differently
	    $year += 1900;
	    $startofday = timelocal(0, 0, 0, $mday, $mon, $year);
	}

	$last = $startofday + $hour*3600 + $min*60;

	my $check_dow = sub {
	    foreach my $d (@$dowspec) {
		return $last if $d == $wday;
		if ($d > $wday) {
		    return $startofday + ($d-$wday)*86400;
		}
	    }
	    return $startofday + (7-$wday)*86400; # start of next week
	};

	if ((my $next = $check_dow->()) != $last) {
	    $last = $next;
	    next; # repeat
	}

	my $check_hour = sub {
	    return $last if $hspec eq '*';
	    foreach my $h (@$hspec) {
		return $last if $h == $hour;
		if ($h > $hour) {
		    return $startofday + $h*3600;
		}
	    }
	    return $startofday + 24*3600; # test next day
	};

	if ((my $next = $check_hour->()) != $last) {
	    $last = $next;
	    next; # repeat
	}

	my $check_minute = sub {
	    return $last if $mspec eq '*';
	    foreach my $m (@$mspec) {
		return $last if $m == $min;
		if ($m > $min) {
		    return $startofday +$hour*3600 + $m*60;
		}
	    }
	    return $startofday + ($hour + 1)*3600; # test next hour
	};

	if ((my $next = $check_minute->()) != $last) {
	    $last = $next;
	    next; # repeat
	} else {
	    return $last;
	}
    }

    die "unable to compute next calendar event\n";
}

1;
