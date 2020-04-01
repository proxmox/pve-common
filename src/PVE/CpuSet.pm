package PVE::CpuSet;

use strict;
use warnings;
use PVE::Tools;
use PVE::ProcFSTools;

sub new {
    my ($class, $members) = @_;

    $members //= {};
    my $self = bless { members => $members }, $class;

    return $self;
}

# Create a new set with the contents of a cgroup-v1 subdirectory.
# Deprecated:
sub new_from_cgroup {
    my ($class, $cgroup, $effective) = @_;

    return $class->new_from_path("/sys/fs/cgroup/cpuset/$cgroup", $effective);
}

# Create a new set from the contents of a complete path to a cgroup directory.
sub new_from_path {
    my ($class, $path, $effective) = @_;

    my $filename;
    if ($effective) {
	$filename = "$path/cpuset.effective_cpus";
	if (!-e $filename) {
	    # cgroupv2:
	    $filename = "$path/cpuset.cpus.effective";
	}
    } else {
	$filename = "$path/cpuset.cpus";
    }

    my $set_text = PVE::Tools::file_read_firstline($filename) // '';

    my ($count, $members) = parse_cpuset($set_text);

    return $class->new($members);
}

sub parse_cpuset {
    my ($set_text) = @_;

    my $members = {};
    my $count = 0;

    foreach my $part (split(/,/, $set_text)) {
	if ($part =~ /^\s*(\d+)(?:-(\d+))?\s*$/) {
	    my ($from, $to) = ($1, $2);
	    $to //= $1;
	    die "invalid range: $part ($to < $from)\n" if $to < $from;
	    for (my $i = $from; $i <= $to; $i++) {
		$members->{$i} = 1;
		$count++;
	    };
	} else {
	    die "invalid range: $part\n";
	}
    }

    return ($count, $members);
}

# Deprecated:
sub write_to_cgroup {
    my ($self, $cgroup) = @_;

    return $self->write_to_path("/sys/fs/cgroup/cpuset/$cgroup");
}

# Takes the cgroup directory containing the cpuset.cpus file (to be closer to
# new_from_path behavior this doesn't take the complete file name).
sub write_to_path {
    my ($self, $path) = @_;

    my $filename = "$path/cpuset.cpus";

    my $value = '';
    my @members = $self->members();
    foreach my $cpuid (@members) {
	$value .= ',' if length($value);
	$value .= $cpuid;
    }

    open(my $fh, '>', $filename) || die "failed to open '$filename' - $!\n";
    PVE::Tools::safe_print($filename, $fh, "$value\n");
    close($fh) || die "failed to close '$filename' - $!\n";
}

sub insert {
    my ($self, @members) = @_;

    my $count = 0;

    foreach my $cpu (@members) {
	next if $self->{members}->{$cpu};
	$self->{members}->{$cpu} = 1;
	$count++;
    }

    return $count;
}

sub delete {
    my ($self, @members) = @_;

    my $count = 0;

    foreach my $cpu (@members) {
	next if !$self->{members}->{$cpu};
	delete $self->{members}->{$cpu};
	$count++;
    }

    return $count;
}

sub has {
   my ($self, $cpuid) = @_;

   return $self->{members}->{$cpuid};
}

# members: this list is always sorted!
sub members {
    my ($self) = @_;

    return sort { $a <=> $b } keys %{$self->{members}};
}

sub size {
    my ($self) = @_;

    return scalar(keys %{$self->{members}});
}

sub is_equal {
    my ($self, $set2) = @_;

    my $members1 = $self->{members};
    my $members2 = $set2->{members};

    foreach my $id (keys %$members1) {
	return 0 if !$members2->{$id};
    }
    foreach my $id (keys %$members2) {
	return 0 if !$members1->{$id};
    }

    return 1;
}

sub short_string {
    my ($self) = @_;

    my @members = $self->members();

    my $res = '';
    my ($last, $next);
    foreach my $cpu (@members) {
	if (!defined($last)) {
	    $last = $next = $cpu;
	} elsif (($next + 1) == $cpu) {
	    $next = $cpu;
	} else {
	    $res .= ',' if length($res);
	    if ($last != $next) {
		$res .= "$last-$next";
	    } else {
		$res .= "$last";
	    }
	    $last = $next = $cpu;
	}
    }

    if (defined($last)) {
	$res .= ',' if length($res);
	if ($last != $next) {
	    $res .= "$last-$next";
	} else {
	    $res .= "$last";
	}
    }

    return $res;
}

1;
