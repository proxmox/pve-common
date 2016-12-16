package PVE::ProcFSTools;

use strict;
use warnings;
use POSIX;
use Time::HiRes qw (gettimeofday);
use IO::File;
use PVE::Tools;
use Cwd qw();

use Socket qw(PF_INET PF_INET6 SOCK_DGRAM IPPROTO_IP);

use constant IFF_UP => 1;
use constant IFNAMSIZ => 16;
use constant SIOCGIFFLAGS => 0x8913;

my $clock_ticks = POSIX::sysconf(&POSIX::_SC_CLK_TCK);

my $cpuinfo;

sub read_cpuinfo {
    my $fn = '/proc/cpuinfo';

    return $cpuinfo if $cpuinfo;

    my $res = {
	user_hz => $clock_ticks,
	model => 'unknown',
	mhz => 0,
	cpus => 1,
	sockets => 1,
    };

    my $fh = IO::File->new ($fn, "r");
    return $res if !$fh;

    my $idhash = {};
    my $count = 0;
    while (defined(my $line = <$fh>)) {
	if ($line =~ m/^processor\s*:\s*\d+\s*$/i) {
	    $count++;
	} elsif ($line =~ m/^model\s+name\s*:\s*(.*)\s*$/i) {
	    $res->{model} = $1 if $res->{model} eq 'unknown';
	} elsif ($line =~ m/^cpu\s+MHz\s*:\s*(\d+\.\d+)\s*$/i) {
	    $res->{mhz} = $1 if !$res->{mhz};
	} elsif ($line =~ m/^flags\s*:.*(vmx|svm)/) {
	    $res->{hvm} = 1; # Hardware Virtual Machine (Intel VT / AMD-V)
	} elsif ($line =~ m/^physical id\s*:\s*(\d+)\s*$/i) {
	    $idhash->{$1} = 1;
	}
    }

    $res->{sockets} = scalar(keys %$idhash) || 1;

    $res->{cpus} = $count;

    $fh->close;
    
    $cpuinfo = $res;

    return $res;
}

sub read_proc_uptime {
    my $ticks = shift;

    my $line = PVE::Tools::file_read_firstline("/proc/uptime");
    if ($line && $line =~ m|^(\d+\.\d+)\s+(\d+\.\d+)\s*$|) {
	if ($ticks) {
	    return (int($1*$clock_ticks), int($2*$clock_ticks));
	} else {
	    return (int($1), int($2));
	}
    }

    return (0, 0);
}

sub read_loadavg {

    my $line = PVE::Tools::file_read_firstline('/proc/loadavg');

    if ($line =~ m|^(\d+\.\d+)\s+(\d+\.\d+)\s+(\d+\.\d+)\s+\d+/\d+\s+\d+\s*$|) {
	return wantarray ? ($1, $2, $3) : $1;
    }

    return wantarray ? (0, 0, 0) : 0;
}

my $last_proc_stat;

sub read_proc_stat {
    my $res = { user => 0, nice => 0, system => 0, idle => 0 , sum => 0};

    my $cpucount = 0;

    if (my $fh = IO::File->new ("/proc/stat", "r")) {
	while (defined (my $line = <$fh>)) {
	    if ($line =~ m|^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s|) {
		$res->{user} = $1;
		$res->{nice} = $2;
		$res->{system} = $3;
		$res->{idle} = $4;
		$res->{used} = $1+$2+$3;
		$res->{iowait} = $5;
	    } elsif ($line =~ m|^cpu\d+\s|) {
		$cpucount++;
	    }
	}
	$fh->close;
    }

    $cpucount = 1 if !$cpucount;

    my $ctime = gettimeofday; # floating point time in seconds

    $res->{ctime} = $ctime;
    $res->{cpu} = 0;
    $res->{wait} = 0;

    $last_proc_stat = $res if !$last_proc_stat;

    my $diff = ($ctime - $last_proc_stat->{ctime}) * $clock_ticks * $cpucount;

    if ($diff > 1000) { # don't update too often
	my $useddiff =  $res->{used} - $last_proc_stat->{used};
	$useddiff = $diff if $useddiff > $diff;
	$res->{cpu} = $useddiff/$diff;
	my $waitdiff =  $res->{iowait} - $last_proc_stat->{iowait};
	$waitdiff = $diff if $waitdiff > $diff;
	$res->{wait} = $waitdiff/$diff;
	$last_proc_stat = $res;
    } else {
	$res->{cpu} = $last_proc_stat->{cpu};
	$res->{wait} = $last_proc_stat->{wait};
    }

    return $res;
}

sub read_proc_pid_stat {
    my $pid = shift;

    my $statstr = PVE::Tools::file_read_firstline("/proc/$pid/stat");

    if ($statstr && $statstr =~ m/^$pid \(.*\) (\S) (-?\d+) -?\d+ -?\d+ -?\d+ -?\d+ \d+ \d+ \d+ \d+ \d+ (\d+) (\d+) (-?\d+) (-?\d+) -?\d+ -?\d+ -?\d+ 0 (\d+) (\d+) (-?\d+) \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ -?\d+ -?\d+ \d+ \d+ \d+/) {
	return {
	    status => $1,
	    utime => $3,
	    stime => $4,
	    starttime => $7,
	    vsize => $8,
	    rss => $9 * 4096,
	};
    }

    return undef;
}

sub check_process_running {
    my ($pid, $pstart) = @_;

    # note: waitpid only work for child processes, but not
    # for processes spanned by other processes.
    # kill(0, pid) return succes for zombies.
    # So we read the status form /proc/$pid/stat instead
 
    my $info = read_proc_pid_stat($pid);
 
    return $info && (!$pstart || ($info->{starttime} eq $pstart)) && ($info->{status} ne 'Z') ? $info : undef;
}

sub read_proc_starttime {
    my $pid = shift;

    my $info = read_proc_pid_stat($pid);
    return $info ? $info->{starttime} : 0;
}

sub read_meminfo {

    my $res = {
	memtotal => 0,
	memfree => 0,
	memused => 0,
	memshared => 0,
	swaptotal => 0,
	swapfree => 0,
	swapused => 0,
    };

    my $fh = IO::File->new ("/proc/meminfo", "r");
    return $res if !$fh;

    my $d = {};
    while (my $line = <$fh>) {
	if ($line =~ m/^(\S+):\s+(\d+)\s*kB/i) {
	    $d->{lc ($1)} = $2 * 1024;
	} 
    }
    close($fh);

    $res->{memtotal} = $d->{memtotal};
    $res->{memfree} =  $d->{memfree} + $d->{buffers} + $d->{cached};
    $res->{memused} = $res->{memtotal} - $res->{memfree};

    $res->{swaptotal} = $d->{swaptotal};
    $res->{swapfree} = $d->{swapfree};
    $res->{swapused} = $res->{swaptotal} - $res->{swapfree};

    my $spages = PVE::Tools::file_read_firstline("/sys/kernel/mm/ksm/pages_sharing");
    $res->{memshared} = int($spages) * 4096;

    return $res;
}

# memory usage of current process
sub read_memory_usage {

    my $res = { size => 0, resident => 0, shared => 0 };

    my $ps = 4096;

    my $line = PVE::Tools::file_read_firstline("/proc/$$/statm");

    if ($line =~ m/^(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*/) {
	$res->{size} = $1*$ps;
	$res->{resident} = $2*$ps;
	$res->{shared} = $3*$ps;
    }

    return $res;
}

sub read_proc_net_dev {

    my $res = {};

    my $fh = IO::File->new ("/proc/net/dev", "r");
    return $res if !$fh;

    while (defined (my $line = <$fh>)) {
	if ($line =~ m/^\s*(.*):\s*(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+/) {
	    $res->{$1} = {
		receive => $2,
		transmit => $3,
	    };
	}
    }

    close($fh);

    return $res;
}

sub write_proc_entry {
    my ($filename, $data) = @_;#

    my $fh = IO::File->new($filename,  O_WRONLY);
    die "unable to open file '$filename' - $!\n" if !$fh;
    die "unable to write '$filename' - $!\n" unless print $fh $data;
    die "closing file '$filename' failed - $!\n" unless close $fh;
    $fh->close();
}

sub read_proc_net_route {
    my $filename = "/proc/net/route";

    my $res = [];

    my $fh = IO::File->new ($filename, "r");
    return $res if !$fh;

    my $int_to_quad = sub {
       return join '.' => map { ($_[0] >> 8*(3-$_)) % 256 } (3, 2, 1, 0);
    };

    while (defined(my $line = <$fh>)) {
       next if $line =~/^Iface\s+Destination/; # skip head
       my ($iface, $dest, $gateway, $metric, $mask, $mtu) = (split(/\s+/, $line))[0,1,2,6,7,8];
       push @$res, {
           dest => &$int_to_quad(hex($dest)),
           gateway => &$int_to_quad(hex($gateway)),
           mask => &$int_to_quad(hex($mask)),
           metric => $metric,
           mtu => $mtu,
	   iface => $iface,
       };
    }

    return $res;
}

sub read_proc_mounts {
    return PVE::Tools::file_get_contents("/proc/mounts", 128*1024);
}

# mounts encode spaces (\040), tabs (\011), newlines (\012), backslashes (\\ or \134)
sub decode_mount {
    my ($str) = @_;
    return $str =~ s/\\(?:040|01[12]|134|\\)/"\"$&\""/geer;
}

sub parse_mounts {
    my ($mounts) = @_;
    my $mntent = [];
    while ($mounts =~ /^\s*([^#].*)$/gm) {
	# lines from the file are encoded so we can just split at spaces
	my ($what, $dir, $fstype, $opts) = split(/[ \t]/, $1, 4);
	my ($freq, $passno) = (0, 0);
	# in glibc's parser frequency and pass seem to be optional
	$freq = $1 if $opts =~ s/\s+(\d+)$//;
	$passno = $1 if $opts =~ s/\s+(\d+)$//;
	push @$mntent, [decode_mount($what),
			decode_mount($dir),
			decode_mount($fstype),
			decode_mount($opts),
			$freq, $passno];
    }
    return $mntent;
}

sub parse_proc_mounts {
    return parse_mounts(read_proc_mounts());
}

sub is_mounted {
    my ($mountpoint) = @_;

    $mountpoint = Cwd::realpath($mountpoint);

    return 0 if !defined($mountpoint); # path does not exist

    my $mounts = parse_proc_mounts();
    return (grep { $_->[1] eq $mountpoint } @$mounts) ? 1 : 0;
}

sub read_proc_net_ipv6_route {
    my $filename = "/proc/net/ipv6_route";

    my $res = [];

    my $fh = IO::File->new ($filename, "r");
    return $res if !$fh;

    my $read_v6addr = sub { $_[0] =~ s/....(?!$)/$&:/gr };

    # ipv6_route has no header
    while (defined(my $line = <$fh>)) {
	my ($dest, $prefix, $nexthop, $metric, $iface) = (split(/\s+/, $line))[0,1,4,5,9];
	push @$res, {
	    dest => &$read_v6addr($dest),
	    prefix => hex("$prefix"),
	    gateway => &$read_v6addr($nexthop),
	    metric => hex("$metric"),
	    iface => $iface
	};
    }

    return $res;
}

sub upid_wait {
    my ($upid, $waitfunc, $sleep_intervall) = @_;

    my $task = PVE::Tools::upid_decode($upid);

    $sleep_intervall = $sleep_intervall ? $sleep_intervall : 1;

    my $next_time = time + $sleep_intervall;

    while (check_process_running($task->{pid}, $task->{pstart})) {

	if (time >= $next_time && $waitfunc && ref($waitfunc) eq 'CODE'){
	    &$waitfunc($task);
	    $next_time = time + $sleep_intervall;
	}

	CORE::sleep(1);
    }
}

# struct ifreq { // FOR SIOCGIFFLAGS:
#   char ifrn_name[IFNAMSIZ]
#   short ifru_flags
# };
my $STRUCT_IFREQ_SIOCGIFFLAGS = 'Z' . IFNAMSIZ . 's1';
sub get_active_network_interfaces {
    # Use the interface name list from /proc/net/dev
    open my $fh, '<', '/proc/net/dev'
	or die "failed to open /proc/net/dev: $!\n";
    # And filter by IFF_UP flag fetched via a PF_INET6 socket ioctl:
    my $sock;
    socket($sock, PF_INET6, SOCK_DGRAM, &IPPROTO_IP)
    or socket($sock, PF_INET, SOCK_DGRAM, &IPPROTO_IP)
    or return [];

    my $ifaces = [];
    while(defined(my $line = <$fh>)) {
	next if $line !~ /^\s*([^:\s]+):/;
	my $ifname = $1;
	my $ifreq = pack($STRUCT_IFREQ_SIOCGIFFLAGS, $ifname, 0);
	if (!defined(ioctl($sock, SIOCGIFFLAGS, $ifreq))) {
	    warn "failed to get interface flags for: $ifname\n";
	    next;
	}
	my ($name, $flags) = unpack($STRUCT_IFREQ_SIOCGIFFLAGS, $ifreq);
	push @$ifaces, $ifname if ($flags & IFF_UP);
    }
    close $fh;
    close $sock;
    return $ifaces;
}

1;
