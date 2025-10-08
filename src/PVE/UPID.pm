package PVE::UPID;

use v5.36;

use PVE::File;

# UPID means 'Unique Process ID' amd uniquely identifies a process in a cluster of nodes.
#
# UPIDs use the following format:
# "UPID:$node:$pid:$pstart:$startime:$dtype:$id:$user"

my $pvelogdir = "/var/log/pve";
my $pvetaskdir = "$pvelogdir/tasks";

mkdir $pvelogdir;
mkdir $pvetaskdir;

sub encode($d) {
    # Note: pstart can be > 32bit if uptime > 497 days, so that field can get longer than 8 chars.
    return sprintf(
        "UPID:%s:%08X:%08X:%08X:%s:%s:%s:",
        $d->{node},
        $d->{pid},
        $d->{pstart},
        $d->{starttime},
        $d->{type},
        $d->{id},
        $d->{user},
    );
}

sub decode($upid, $noerr = 0) {
    # "UPID:$node:$pid:$pstart:$startime:$dtype:$id:$user"
    # Note: allow up to 9 characters for pstart, that works for 20 years continuous uptime.
    if ($upid =~
        m|^UPID:([a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?):([0-9A-Fa-f]{8}):([0-9A-Fa-f]{8,9}):([0-9A-Fa-f]{8}):([^:\s/]+):([^:\s/]*):([^:\s/]+):$|
    ) {
        my $res = {
            node => $1,
            pid => hex($3),
            pstart => hex($4),
            starttime => hex($5),
            type => $6,
            id => $7,
            user => $8,
        };

        my $subdir = substr($5, 7, 8);
        my $filename = "$pvetaskdir/$subdir/$upid";

        return wantarray ? ($res, $filename) : $res;
    }

    return undef if $noerr;
    die "unable to parse worker upid '$upid'\n";
}

sub open_log($upid) {
    my ($task, $filename) = decode($upid);

    my $wwwid = getpwnam('www-data') || die "getpwnam failed";

    my $new_log_fh = PVE::File::create_owned_file_fh($filename, $wwwid);

    return $new_log_fh;
}

sub read_status($upid) {
    my ($task, $filename) = decode($upid);

    my $line = eval { PVE::File::file_read_last_line($filename) };
    return "unable to get last line from task log - $@" if $@;

    if ($line =~ m/^TASK OK$/) {
        return 'OK';
    } elsif ($line =~ m/^TASK ERROR: (.+)$/) {
        return $1;
    } elsif ($line =~ m/^TASK (WARNINGS: \d+)$/) {
        return $1;
    } else {
        return "unexpected status";
    }
}

# Check if the status returned by read_status is an error status.
# If the status could not be parsed it's also treated as an error.
sub status_is_error($status) {
    return !($status eq 'OK' || $status =~ m/^WARNINGS: \d+$/);
}

# takes the parsed status and returns the type, either ok, warning, error or unknown
sub normalize_status_type($status) {
    if (!$status) {
        return 'unknown';
    } elsif ($status eq 'OK') {
        return 'ok';
    } elsif ($status =~ m/^WARNINGS: \d+$/) {
        return 'warning';
    } elsif ($status eq 'unexpected status') {
        return 'unknown';
    } else {
        return 'error';
    }
}

1;
