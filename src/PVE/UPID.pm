package PVE::UPID;

use v5.36;

use IO::File;
use File::Path qw(make_path);

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

sub decode($upid, $noerr) {
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

    my $dirname = dirname($filename);
    make_path($dirname);

    my $wwwid = getpwnam('www-data')
        || die "getpwnam failed";

    my $perm = 0640;

    my $outfh = IO::File->new($filename, O_WRONLY | O_CREAT | O_EXCL, $perm)
        || die "unable to create output file '$filename' - $!\n";
    chown $wwwid, -1, $outfh;

    return $outfh;
}

sub read_status($upid) {
    my ($task, $filename) = decode($upid);
    my $fh = IO::File->new($filename, "r") or return "unable to open file - $!";

    my $maxlen = 4096;
    sysseek($fh, -$maxlen, 2);
    my $readbuf = '';
    my $br = sysread($fh, $readbuf, $maxlen);
    close($fh);

    if ($br) {
        return "unable to extract last line" if $readbuf !~ m/\n?(.+)$/; my $line = $1;

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
    return "unable to read tail (got $br bytes)";
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
