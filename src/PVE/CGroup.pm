# cgroup handler
#
# This package should deal with figuring out the right cgroup path for a
# container (via the command socket), reading and writing cgroup values, and
# handling cgroup v1 & v2 differences.
#
# Note that the long term plan is to have resource manage functions instead of
# dealing with cgroup files on the outside.

package PVE::CGroup;

use strict;
use warnings;

use IO::File;
use IO::Select;
use POSIX qw();

use PVE::ProcFSTools;
use PVE::Tools qw(
    file_get_contents
    file_read_firstline
);

# We don't want to do a command socket round trip for every cgroup read/write,
# so any cgroup function needs to have the container's path cached, so this
# package has to be instantiated.
#
# LXC keeps separate paths by controller (although they're normally all the
# same, in our # case anyway), so we cache them by controller as well.
sub new {
    my ($class, $vmid) = @_;

    my $self = { vmid => $vmid };

    return bless $self, $class;
}

# Get the v1 controller list.
#
# Returns a set (hash mapping names to `1`) of cgroupv1 controllers, and an
# optional boolean whether a unified (cgroupv2) hierarchy exists.
my sub get_v1_controllers {
    my $v1 = {};
    my $v2 = 0;
    my $data = PVE::Tools::file_get_contents('/proc/self/cgroup');
    while ($data =~ /^\d+:([^:\n]*):.*$/gm) {
	my $type = $1;
	if (length($type)) {
	    $v1->{$_} = 1 foreach split(/,/, $type);
	} else {
	    $v2 = 1;
	}
    }
    return wantarray ? ($v1, $v2) : $v1;
}

# Get the set v2 controller list from the `cgroup.controllers` file.
my sub get_v2_controllers {
    my $v2 = eval { file_get_contents('/sys/fs/cgroup/cgroup.controllers') }
	|| eval { file_get_contents('/sys/fs/cgroup/unified/cgroup.controllers') };
    return undef if !defined $v2;

    # It's a simple space separated list:
    return { map { $_ => 1 } split(/\s+/, $v2) };
}

my $CGROUP_CONTROLLERS = undef;
# Get a list of controllers enabled in each cgroup subsystem.
#
# This is a more complete version of `PVE::LXC::get_cgroup_subsystems`.
#
# Returns 2 sets (hashes mapping controller names to `1`), one for each cgroup
# version.
sub get_cgroup_controllers() {
    if (!defined($CGROUP_CONTROLLERS)) {
	my ($v1, undef) = get_v1_controllers();
	my $v2 = get_v2_controllers();

	$CGROUP_CONTROLLERS = [$v1, $v2];
    }

    return $CGROUP_CONTROLLERS->@*;
}

my $CGROUP_MODE = undef;
# Figure out which cgroup mode we're operating under:
#
# For this we check the file system type of `/sys/fs/cgroup` as it may well be possible that some
# additional cgroupv1 mount points have been created by tools such as `systemd-nspawn`, or
# manually.
#
# Returns 1 for what we consider the hybrid layout, 2 for what we consider the unified layout.
#
# NOTE: To fully support a hybrid layout it is better to use functions like
# `cpuset_controller_path` and not rely on this value for anything involving paths.
#
# This is a function, not a method!
sub cgroup_mode() {
    if (!defined($CGROUP_MODE)) {
	my $mounts = PVE::ProcFSTools::parse_proc_mounts();
	for my $entry (@$mounts) {
	    my ($what, $dir, $fstype, $opts) = @$entry;
	    if ($dir eq '/sys/fs/cgroup') {
		if ($fstype eq 'cgroup2') {
		    $CGROUP_MODE = 2;
		    last;
		} else {
		    $CGROUP_MODE = 1;
		    last;
		}
	    }
	}
    }

    die "unknown cgroup mode\n" if !defined($CGROUP_MODE);
    return $CGROUP_MODE;
}

my $CGROUPV2_PATH = undef;
sub cgroupv2_base_path() {
    if (!defined($CGROUPV2_PATH)) {
	if (cgroup_mode() == 2) {
	    $CGROUPV2_PATH = '/sys/fs/cgroup';
	} else {
	    $CGROUPV2_PATH = '/sys/fs/cgroup/unified';
	}
    }
    return $CGROUPV2_PATH;
}

# Find a cgroup controller and return its path and version.
#
# LXC initializes the unified hierarchy first, so if a controller is
# available via both we favor cgroupv2 here as well.
#
# Returns nothing if the controller is not available.

sub find_cgroup_controller($) {
    my ($controller) = @_;

    my ($v1, $v2) = get_cgroup_controllers();

    if (!defined($controller) || $v2->{$controller}) {
	my $path = cgroupv2_base_path();
	return wantarray ? ($path, 2) : $path;
    }

    if (defined($controller) && $v1->{$controller}) {
	my $path = "/sys/fs/cgroup/$controller";
	return wantarray ? ($path, 1) : $path;
    }

    return;
}

my $CG_PATH_CPUSET = undef;
my $CG_VER_CPUSET = undef;
# Find the cpuset cgroup controller.
#
# This is a function, not a method!
sub cpuset_controller_path() {
    if (!defined($CG_PATH_CPUSET)) {
	($CG_PATH_CPUSET, $CG_VER_CPUSET) = find_cgroup_controller('cpuset')
	    or die "failed to find cpuset controller\n";
    }

    return wantarray ? ($CG_PATH_CPUSET, $CG_VER_CPUSET) : $CG_PATH_CPUSET;
}

# Get a subdirectory (without the cgroup mount point) for a controller.
sub get_subdir {
    my ($self, $controller, $limiting) = @_;

    die "implement in subclass";
}

# Get path and version for a controller.
#
# `$controller` may be `undef`, see get_subdir above for details.
#
# Returns either just the path, or the path and cgroup version as a tuple.
sub get_path {
    my ($self, $controller, $limiting) = @_;
    # Find the controller before querying the lxc monitor via a socket:
    my ($cgpath, $ver) = find_cgroup_controller($controller)
	or return undef;

    my $path = $self->get_subdir($controller, $limiting)
	or return undef;

    $path = "$cgpath/$path";
    return wantarray ? ($path, $ver) : $path;
}

# Convenience method to get the path info if the first existing controller.
#
# Returns the same as `get_path`.
sub get_any_path {
    my ($self, $limiting, @controllers) = @_;

    my ($path, $ver);
    for my $c (@controllers) {
	($path, $ver) = $self->get_path($c, $limiting);
	last if defined $path;
    }
    return wantarray ? ($path, $ver) : $path;
}

# Parse a 'Nested keyed' file:
#
# See kernel documentation `admin-guide/cgroup-v2.rst` 4.1.
my sub parse_nested_keyed_file($) {
    my ($data) = @_;
    my $res = {};
    foreach my $line (split(/\n/, $data)) {
	my ($key, @values) = split(/\s+/, $line);

	my $d = ($res->{$key} = {});

	foreach my $value (@values) {
	    if (my ($key, $value) = ($value =~ /^([^=]+)=(.*)$/)) {
		$d->{$key} = $value;
	    } else {
		warn "bad key=value pair in nested keyed file\n";
	    }
	}
    }
    return $res;
}

# Parse a 'Flat keyed' file:
#
# See kernel documentation `admin-guide/cgroup-v2.rst` 4.1.
my sub parse_flat_keyed_file($) {
    my ($data) = @_;
    my $res = {};
    foreach my $line (split(/\n/, $data)) {
	if (my ($key, $value) = ($line =~ /^(\S+)\s+(.*)$/)) {
	    $res->{$key} = $value;
	} else {
	    warn "bad 'key value' pair in flat keyed file\n";
	}
    }
    return $res;
}

# Parse out 'diskread' and 'diskwrite' values from I/O stats for this container.
sub get_io_stats {
    my ($self) = @_;

    my $res = {
	diskread => 0,
	diskwrite => 0,
    };

    # With cgroupv1 we have a 'blkio' controller, with cgroupv2 it's just 'io':
    my ($path, $ver) = $self->get_any_path(1, 'io', 'blkio');
    if (!defined($path)) {
	# container not running
	return undef;
    } elsif ($ver == 2) {
	# cgroupv2 environment, io controller enabled
	my $io_stat = file_get_contents("$path/io.stat");

	my $data = parse_nested_keyed_file($io_stat);
	foreach my $dev (keys %$data) {
	    my $dev = $data->{$dev};
	    if (my $b = $dev->{rbytes}) {
		$res->{diskread} += $b;
	    }
	    if (my $b = $dev->{wbytes}) {
		$res->{diskwrite} += $b;
	    }
	}

	return $res;
    } elsif ($ver == 1) {
	# cgroupv1 environment:
	my $io = file_get_contents("$path/blkio.throttle.io_service_bytes_recursive");
	foreach my $line (split(/\n/, $io)) {
	    if (my ($type, $bytes) = ($line =~ /^\d+:\d+\s+(Read|Write)\s+(\d+)$/)) {
		$res->{diskread} += $bytes if $type eq 'Read';
		$res->{diskwrite} += $bytes if $type eq 'Write';
	    }
	}

	return $res;
    } else {
	die "bad cgroup version: $ver\n";
    }

    # container not running
    return undef;
}

# Read utime and stime for this container from the cpuacct cgroup.
# Values are in milliseconds!
sub get_cpu_stat {
    my ($self) = @_;

    my $res = {
	utime => 0,
	stime => 0,
    };

    my ($path, $ver) = $self->get_any_path(1, 'cpuacct', 'cpu');
    if (!defined($path)) {
	# container not running
	return undef;
    } elsif ($ver == 2) {
	my $data = eval { file_get_contents("$path/cpu.stat") };

	# or no io controller available:
	return undef if !defined($data);

	$data = parse_flat_keyed_file($data);
	$res->{utime} = int($data->{user_usec} / 1000);
	$res->{stime} = int($data->{system_usec} / 1000);
    } elsif ($ver == 1) {
	# cgroupv1 environment:
	my $clock_ticks = POSIX::sysconf(&POSIX::_SC_CLK_TCK);
	my $clk_to_usec = 1000 / $clock_ticks;

	my $data = parse_flat_keyed_file(file_get_contents("$path/cpuacct.stat"));
	$res->{utime} = int($data->{user} * $clk_to_usec);
	$res->{stime} = int($data->{system} * $clk_to_usec);
    } else {
	die "bad cgroup version: $ver\n";
    }

    return $res;
}

# Parse some memory data from `memory.stat`
sub get_memory_stat {
    my ($self) = @_;

    my $res = {
	mem => 0,
	swap => 0,
    };

    my ($path, $ver) = $self->get_path('memory', 1);
    if (!defined($path)) {
	# container most likely isn't running
	return undef;
    } elsif ($ver == 2) {
	my $mem = file_get_contents("$path/memory.current");
	my $swap = file_get_contents("$path/memory.swap.current");
	my $stat = parse_flat_keyed_file(file_get_contents("$path/memory.stat"));

	chomp ($mem, $swap);

	$res->{mem} = $mem - $stat->{file};
	$res->{swap} = $swap;
    } elsif ($ver == 1) {
	# cgroupv1 environment:
	my $stat = parse_flat_keyed_file(file_get_contents("$path/memory.stat"));
	my $mem = file_get_contents("$path/memory.usage_in_bytes");
	my $memsw = file_get_contents("$path/memory.memsw.usage_in_bytes");
	chomp ($mem, $memsw);

	$res->{mem} = $mem - $stat->{total_cache};
	$res->{swap} = $memsw - $mem;
    } else {
	die "bad cgroup version: $ver\n";
    }

    return $res;
}

sub get_pressure_stat {
    my ($self) = @_;

    my $res = {
	cpu => {
	    some => { avg10 => 0, avg60 => 0, avg300 => 0 }
	},
	memory => {
	    some => { avg10 => 0, avg60 => 0, avg300 => 0 },
	    full => { avg10 => 0, avg60 => 0, avg300 => 0 }
	},
	io => {
	    some => { avg10 => 0, avg60 => 0, avg300 => 0 },
	    full => { avg10 => 0, avg60 => 0, avg300 => 0 }
	},
    };

    my ($path, $version) = $self->get_path(undef, 1);
    if (!defined($path)) {
	return $res; # container or VM most likely isn't running, retrun zero stats
    } elsif ($version == 1) {
	return undef; # v1 controller does not provides pressure stat
    } elsif ($version == 2) {
	for my $type (qw(cpu memory io)) {
	    my $stats = PVE::ProcFSTools::parse_pressure("$path/$type.pressure");
	    $res->{$type} = $stats if $stats;
	}
    } else {
	die "bad cgroup version: $version\n";
    }

    return $res;
}

# Change the memory limit for this container.
#
# Dies on error (including a not-running or currently-shutting-down guest).
sub change_memory_limit {
    my ($self, $mem_bytes, $swap_bytes) = @_;

    my ($path, $ver) = $self->get_path('memory', 1);
    if (!defined($path)) {
	die "trying to change memory cgroup values: container not running\n";
    } elsif ($ver == 2) {
	PVE::ProcFSTools::write_proc_entry("$path/memory.swap.max", $swap_bytes)
	    if defined($swap_bytes);
	PVE::ProcFSTools::write_proc_entry("$path/memory.max", $mem_bytes)
	    if defined($mem_bytes);
    } elsif ($ver == 1) {
	# With cgroupv1 we cannot control memory and swap limits separately.
	# This also means that since the two values aren't independent, we need to handle
	# growing and shrinking separately.
	my $path_mem = "$path/memory.limit_in_bytes";
	my $path_memsw = "$path/memory.memsw.limit_in_bytes";

	my $old_mem_bytes = file_get_contents($path_mem);
	my $old_memsw_bytes = file_get_contents($path_memsw);
	chomp($old_mem_bytes, $old_memsw_bytes);

	$mem_bytes //= $old_mem_bytes;
	$swap_bytes //= $old_memsw_bytes - $old_mem_bytes;
	my $memsw_bytes = $mem_bytes + $swap_bytes;

	if ($memsw_bytes > $old_memsw_bytes) {
	    # Growing the limit means growing the combined limit first, then pulling the
	    # memory limitup.
	    PVE::ProcFSTools::write_proc_entry($path_memsw, $memsw_bytes);
	    PVE::ProcFSTools::write_proc_entry($path_mem, $mem_bytes);
	} else {
	    # Shrinking means we first need to shrink the mem-only memsw cannot be
	    # shrunk below it.
	    PVE::ProcFSTools::write_proc_entry($path_mem, $mem_bytes);
	    PVE::ProcFSTools::write_proc_entry($path_memsw, $memsw_bytes);
	}
    } else {
	die "bad cgroup version: $ver\n";
    }

    # return a truth value
    return 1;
}

# Change the cpu quota for a container.
#
# Dies on error (including a not-running or currently-shutting-down guest).
sub change_cpu_quota {
    my ($self, $quota, $period) = @_;

    die "quota without period not allowed\n" if !defined($period) && defined($quota);

    my ($path, $ver) = $self->get_path('cpu', 1);
    if (!defined($path)) {
	die "trying to change cpu quota cgroup values: container not running\n";
    } elsif ($ver == 2) {
	# cgroupv2 environment, an undefined (unlimited) quota is defined as "max"
	# in this interface:
	$quota //= 'max'; # unlimited
	if (defined($quota)) {
	    PVE::ProcFSTools::write_proc_entry("$path/cpu.max", "$quota $period");
	} else {
	    # we're allowed to only write the quota:
	    PVE::ProcFSTools::write_proc_entry("$path/cpu.max", 'max');
	}
    } elsif ($ver == 1) {
	$quota //= -1; # default (unlimited)
	$period //= 100_000; # default (100 ms)
	PVE::ProcFSTools::write_proc_entry("$path/cpu.cfs_period_us", $period);
	PVE::ProcFSTools::write_proc_entry("$path/cpu.cfs_quota_us", $quota);
    } else {
	die "bad cgroup version: $ver\n";
    }

    # return a truth value
    return 1;
}

# Clamp an integer to the supported range of CPU shares from the booted CGroup version
#
# Returns the default if called with an undefined value.
sub clamp_cpu_shares {
    my ($shares) = @_;

    my $is_cgroupv2 = cgroup_mode() == 2;

    return $is_cgroupv2 ? 100 : 1024 if !defined($shares);

    if ($is_cgroupv2) {
	$shares = 10000 if $shares >= 10000; # v1 can be higher, so clamp v2 there
    } else {
	$shares = 2 if $shares < 2; # v2 can be lower, so clamp v1 there
    }
    return $shares;
}

# Change the cpu "shares" for a container.
#
# In cgroupv1 we used a value in `[0..500000]` with a default of 1024.
#
# In cgroupv2 we do not have "shares", we have "weights" in the range
# of `[1..10000]` with a default of 100.
#
# Since the default values don't match when scaling linearly, we use the
# values we get as-is and simply error for values >10000 in cgroupv2.
#
# It is left to the user to figure this out for now.
#
# Dies on error (including a not-running or currently-shutting-down guest).
#
# NOTE: if you add a new param during 7.x you need to break older pve-container/qemu-server versions
#  that previously passed a `$cgroupv1_default`, which got removed due to being ignored anyway.
#  otherwise you risk that a old module bogusly passes some cgroup default as your new param.
sub change_cpu_shares {
    my ($self, $shares) = @_;

    my ($path, $ver) = $self->get_path('cpu', 1);
    if (!defined($path)) {
	die "trying to change cpu shares/weight cgroup values: container not running\n";
    } elsif ($ver == 2) {
	# the cgroupv2 documentation defines the default to 100
	$shares //= 100;
	die "cpu weight (shares) must be in range [1, 10000]\n" if $shares < 1 || $shares > 10000;
	PVE::ProcFSTools::write_proc_entry("$path/cpu.weight", $shares);
    } elsif ($ver == 1) {
	$shares //= 1024;
	PVE::ProcFSTools::write_proc_entry("$path/cpu.shares", $shares);
    } else {
	die "bad cgroup version: $ver\n";
    }

    # return a truth value
    return 1;
}

my sub v1_freeze_thaw {
    my ($self, $controller_path, $freeze) = @_;
    my $path = $self->get_subdir('freezer', 1)
	or die "trying to freeze container: container not running\n";
    $path = "$controller_path/$path/freezer.state";

    my $data = $freeze ? 'FROZEN' : 'THAWED';
    PVE::ProcFSTools::write_proc_entry($path, $data);

    # Here we just poll the freezer.state once per second.
    while (1) {
	my $state = file_get_contents($path);
	chomp $state;
	last if $state eq $data;
    }
}

my sub v2_freeze_thaw {
    my ($self, $controller_path, $freeze) = @_;
    my $path = $self->get_subdir(undef, 1)
	or die "trying to freeze container: container not running\n";
    $path = "$controller_path/$path";

    my $desired_state = $freeze ? 1 : 0;

    # cgroupv2 supports poll events on cgroup.events which contains the frozen
    # state.
    my $fh = IO::File->new("$path/cgroup.events", 'r')
	or die "failed to open $path/cgroup.events file: $!\n";
    my $select = IO::Select->new();
    $select->add($fh);

    PVE::ProcFSTools::write_proc_entry("$path/cgroup.freeze", $desired_state);
    while (1) {
	my $data = do {
	    local $/ = undef;
	    <$fh>
	};
	$data = parse_flat_keyed_file($data);
	last if $data->{frozen} == $desired_state;
	my @handles = $select->has_exception();
	next if !@handles;
	seek($fh, 0, 0)
	    or die "failed to rewind cgroup.events file: $!\n";
    }
}

# Freeze or unfreeze a container.
#
# This will freeze the container at its outer (limiting) cgroup path. We use
# this instead of `lxc-freeze` as `lxc-freeze` from lxc4 will not be able to
# fetch the cgroup path from contaienrs still running on lxc3.
sub freeze_thaw {
    my ($self, $freeze) = @_;

    my $controller_path = find_cgroup_controller('freezer');
    if (defined($controller_path)) {
	return v1_freeze_thaw($self, $controller_path, $freeze);
    } else {
	# cgroupv2 always has a freezer, there can be both cgv1 and cgv2
	# freezers, but we'll prefer v1 when it's available as that's what lxc
	# does as well...
	return v2_freeze_thaw($self, cgroupv2_base_path(), $freeze);
    }
}

1;
