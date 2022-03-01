package PVE::CalendarEvent;

use strict;
use warnings;
use Data::Dumper;
use Time::Local;
use PVE::JSONSchema;
use PVE::Tools qw(trim);
use Proxmox::RS::CalendarEvent;

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

    return Proxmox::RS::CalendarEvent->new($event);
}

sub compute_next_event {
    my ($calspec, $last) = @_;

    return $calspec->compute_next_event($last);
}

1;
