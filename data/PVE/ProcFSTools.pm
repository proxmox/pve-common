package PVE::ProcFSTools;

use strict;
use POSIX;
use Time::HiRes qw (gettimeofday);
use IO::File;
use PVE::Tools;

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
    };

    my $fh = IO::File->new ($fn, "r");
    return $res if !$fh;

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
	}
    }

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
	    return (int($1*100), int($2*100));
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

sub read_proc_starttime {
    my $pid = shift;

    my $statstr = PVE::Tools::file_read_firstline("/proc/$pid/stat");

    if ($statstr && $statstr =~ m/^$pid \(.*\) \S (-?\d+) -?\d+ -?\d+ -?\d+ -?\d+ \d+ \d+ \d+ \d+ \d+ (\d+) (\d+) (-?\d+) (-?\d+) -?\d+ -?\d+ -?\d+ 0 (\d+) (\d+) (-?\d+) \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ \d+ -?\d+ -?\d+ \d+ \d+ \d+/) {
	my $starttime = $6;

	return $starttime;
    }

    return 0;
}

sub read_meminfo {

    my $res = {
	memtotal => 0,
	memfree => 0,
	memused => 0,
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

    return $res;
}

# memory usage of current process
sub read_memory_usage {

    my $res = { size => 0, resident => 0, shared => 0 };

    my $ps = 4096;

    my $line = PVE::Tools::file_read_firstline("/proc/$$/statm");

    if ($line =~ m/^(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+/) {
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

1;
