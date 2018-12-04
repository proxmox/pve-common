package PVE::AbstractConfig;

use strict;
use warnings;

use PVE::Tools qw(lock_file lock_file_full);
use PVE::INotify;

my $nodename = PVE::INotify::nodename();

# Printable string, currently either "VM" or "CT"
sub guest_type {
    my ($class) = @_;
    die "abstract method - implement me ";
}

sub __config_max_unused_disks {
    my ($class) = @_;

    die "implement me - abstract method\n";
}

# Path to the flock file for this VM/CT
sub config_file_lock {
    my ($class, $vmid) = @_;
    die "abstract method - implement me";
}

# Relative config file path for this VM/CT in CFS
sub cfs_config_path {
    my ($class, $vmid, $node) = @_;
    die "abstract method - implement me";
}

# Absolute config file path for this VM/CT
sub config_file {
    my ($class, $vmid, $node) = @_;

    my $cfspath = $class->cfs_config_path($vmid, $node);
    return "/etc/pve/$cfspath";
}

# Read and parse config file for this VM/CT
sub load_config {
    my ($class, $vmid, $node) = @_;

    $node = $nodename if !$node;
    my $cfspath = $class->cfs_config_path($vmid, $node);

    my $conf = PVE::Cluster::cfs_read_file($cfspath);
    die "Configuration file '$cfspath' does not exist\n"
	if !defined($conf);

    return $conf;
}

# Generate and write config file for this VM/CT
sub write_config {
    my ($class, $vmid, $conf) = @_;

    my $cfspath = $class->cfs_config_path($vmid);

    PVE::Cluster::cfs_write_file($cfspath, $conf);
}

# Lock config file using flock, run $code with @param, unlock config file.
# $timeout is the maximum time to acquire the flock
sub lock_config_full {
    my ($class, $vmid, $timeout, $code, @param) = @_;

    my $filename = $class->config_file_lock($vmid);

    my $res = lock_file($filename, $timeout, $code, @param);

    die $@ if $@;

    return $res;
}

# Lock config file using flock, run $code with @param, unlock config file.
# $timeout is the maximum time to acquire the flock
# $shared eq 1 creates a non-exclusive ("read") flock
sub lock_config_mode {
    my ($class, $vmid, $timeout, $shared, $code, @param) = @_;

    my $filename = $class->config_file_lock($vmid);

    my $res = lock_file_full($filename, $timeout, $shared, $code, @param);

    die $@ if $@;

    return $res;
}

# Lock config file using flock, run $code with @param, unlock config file.
sub lock_config {
    my ($class, $vmid, $code, @param) = @_;

    return $class->lock_config_full($vmid, 10, $code, @param);
}

# Checks whether the config is locked with the lock parameter
sub check_lock {
    my ($class, $conf) = @_;

    die $class->guest_type()." is locked ($conf->{lock})\n" if $conf->{lock};
}

# Returns whether the config is locked with the lock parameter, also checks
# whether the lock value is correct if the optional $lock is set.
sub has_lock {
    my ($class, $conf, $lock) = @_;

    return $conf->{lock} && (!defined($lock) || $lock eq $conf->{lock});
}

# Sets the lock parameter for this VM/CT's config to $lock.
sub set_lock {
    my ($class, $vmid, $lock) = @_;

    my $conf;
    $class->lock_config($vmid, sub {
	$conf = $class->load_config($vmid);
	$class->check_lock($conf);
	$conf->{lock} = $lock;
	$class->write_config($vmid, $conf);
    });
    return $conf;
}

# Removes the lock parameter for this VM/CT's config, also checks whether
# the lock value is correct if the optional $lock is set.
sub remove_lock {
    my ($class, $vmid, $lock) = @_;

    $class->lock_config($vmid, sub {
	my $conf = $class->load_config($vmid);
	if (!$conf->{lock}) {
	    my $lockstring = defined($lock) ? "'$lock' " : "any";
	    die "no lock found trying to remove $lockstring lock\n";
	} elsif (defined($lock) && $conf->{lock} ne $lock) {
	    die "found lock '$conf->{lock}' trying to remove '$lock' lock\n";
	}
	delete $conf->{lock};
	$class->write_config($vmid, $conf);
    });
}

# Checks whether protection mode is enabled for this VM/CT.
sub check_protection {
    my ($class, $conf, $err_msg) = @_;

    if ($conf->{protection}) {
	die "$err_msg - protection mode enabled\n";
    }
}

# Adds an unused volume to $config, if possible.
sub add_unused_volume {
    my ($class, $config, $volid) = @_;

    my $key;
    for (my $ind = $class->__config_max_unused_disks() - 1; $ind >= 0; $ind--) {
	my $test = "unused$ind";
	if (my $vid = $config->{$test}) {
	    return if $vid eq $volid; # do not add duplicates
	} else {
	    $key = $test;
	}
    }

    die "Too many unused volumes - please delete them first.\n" if !$key;

    $config->{$key} = $volid;

    return $key;
}

# Returns whether the template parameter is set in $conf.
sub is_template {
    my ($class, $conf) = @_;

    return 1 if defined $conf->{template} && $conf->{template} == 1;
}

# Checks whether $feature is availabe for the referenced volumes in $conf.
# Note: depending on the parameters, some volumes may be skipped!
sub has_feature {
    my ($class, $feature, $conf, $storecfg, $snapname, $running, $backup_only) = @_;
    die "implement me - abstract method\n";
}

# Internal snapshots

# NOTE: Snapshot create/delete involves several non-atomic
# actions, and can take a long time.
# So we try to avoid locking the file and use the 'lock' variable
# inside the config file instead.

# Save the vmstate (RAM).
sub __snapshot_save_vmstate {
    my ($class, $vmid, $conf, $snapname, $storecfg) = @_;
    die "implement me - abstract method\n";
}

# Check whether the VM/CT is running.
sub __snapshot_check_running {
    my ($class, $vmid) = @_;
    die "implement me - abstract method\n";
}

# Check whether we need to freeze the VM/CT
sub __snapshot_check_freeze_needed {
    my ($sself, $vmid, $config, $save_vmstate) = @_;
    die "implement me - abstract method\n";
}

# Freeze or unfreeze the VM/CT.
sub __snapshot_freeze {
    my ($class, $vmid, $unfreeze) = @_;

    die "abstract method - implement me\n";
}

# Code run before and after creating all the volume snapshots
# base: noop
sub __snapshot_create_vol_snapshots_hook {
    my ($class, $vmid, $snap, $running, $hook) = @_;

    return;
}

# Create the volume snapshots for the VM/CT.
sub __snapshot_create_vol_snapshot {
    my ($class, $vmid, $vs, $volume, $snapname) = @_;

    die "abstract method - implement me\n";
}

# Remove a drive from the snapshot config.
sub __snapshot_delete_remove_drive {
    my ($class, $snap, $remove_drive) = @_;

    die "abstract method - implement me\n";
}

# Delete the vmstate file/drive
sub __snapshot_delete_vmstate_file {
    my ($class, $snap, $force) = @_;

    die "abstract method - implement me\n";
}

# Delete a volume snapshot
sub __snapshot_delete_vol_snapshot {
    my ($class, $vmid, $vs, $volume, $snapname) = @_;

    die "abstract method - implement me\n";
}

# Checks whether a volume snapshot is possible for this volume.
sub __snapshot_rollback_vol_possible {
    my ($class, $volume, $snapname) = @_;

    die "abstract method - implement me\n";
}

# Rolls back this volume.
sub __snapshot_rollback_vol_rollback {
    my ($class, $volume, $snapname) = @_;

    die "abstract method - implement me\n";
}

# Stops the VM/CT for a rollback.
sub __snapshot_rollback_vm_stop {
    my ($class, $vmid) = @_;

    die "abstract method - implement me\n";
}

# Start the VM/CT after a rollback with restored vmstate.
sub __snapshot_rollback_vm_start {
    my ($class, $vmid, $vmstate, $forcemachine);

    die "abstract method - implement me\n";
}

# Iterate over all configured volumes, calling $func for each key/value pair.
sub __snapshot_foreach_volume {
    my ($class, $conf, $func) = @_;

    die "abstract method - implement me\n";
}

# Copy the current config $source to the snapshot config $dest
sub __snapshot_copy_config {
    my ($class, $source, $dest) = @_;

    foreach my $k (keys %$source) {
	next if $k eq 'snapshots';
	next if $k eq 'snapstate';
	next if $k eq 'snaptime';
	next if $k eq 'vmstate';
	next if $k eq 'lock';
	next if $k eq 'digest';
	next if $k eq 'description';
	next if $k =~ m/^unused\d+$/;

	$dest->{$k} = $source->{$k};
    }
};

# Apply the snapshot config $snap to the config $conf (rollback)
sub __snapshot_apply_config {
    my ($class, $conf, $snap) = @_;

    # copy snapshot list
    my $newconf = {
	snapshots => $conf->{snapshots},
    };

    # keep description and list of unused disks
    foreach my $k (keys %$conf) {
	next if !($k =~ m/^unused\d+$/ || $k eq 'description');
	$newconf->{$k} = $conf->{$k};
    }

    $class->__snapshot_copy_config($snap, $newconf);

    return $newconf;
}

# Prepares the configuration for snapshotting.
sub __snapshot_prepare {
    my ($class, $vmid, $snapname, $save_vmstate, $comment) = @_;

    my $snap;

    my $updatefn =  sub {

	my $conf = $class->load_config($vmid);

	die "you can't take a snapshot if it's a template\n"
	    if $class->is_template($conf);

	$class->check_lock($conf);

	$conf->{lock} = 'snapshot';

	die "snapshot name '$snapname' already used\n"
	    if defined($conf->{snapshots}->{$snapname});

	my $storecfg = PVE::Storage::config();
	die "snapshot feature is not available\n"
	    if !$class->has_feature('snapshot', $conf, $storecfg, undef, undef, $snapname eq 'vzdump');

	$snap = $conf->{snapshots}->{$snapname} = {};

	if ($save_vmstate && $class->__snapshot_check_running($vmid)) {
	    $class->__snapshot_save_vmstate($vmid, $conf, $snapname, $storecfg);
	}

	$class->__snapshot_copy_config($conf, $snap);

	$snap->{snapstate} = "prepare";
	$snap->{snaptime} = time();
	$snap->{description} = $comment if $comment;

	$class->write_config($vmid, $conf);
    };

    $class->lock_config($vmid, $updatefn);

    return $snap;
}

# Commits the configuration after snapshotting.
sub __snapshot_commit {
    my ($class, $vmid, $snapname) = @_;

    my $updatefn = sub {

	my $conf = $class->load_config($vmid);

	die "missing snapshot lock\n"
	    if !($conf->{lock} && $conf->{lock} eq 'snapshot');

	my $snap = $conf->{snapshots}->{$snapname};
	die "snapshot '$snapname' does not exist\n" if !defined($snap);

	die "wrong snapshot state\n"
	    if !($snap->{snapstate} && $snap->{snapstate} eq "prepare");

	delete $snap->{snapstate};
	delete $conf->{lock};

	$conf->{parent} = $snapname;

	$class->write_config($vmid, $conf);
    };

    $class->lock_config($vmid, $updatefn);
}

# Creates a snapshot for the VM/CT.
sub snapshot_create {
    my ($class, $vmid, $snapname, $save_vmstate, $comment) = @_;

    my $snap = $class->__snapshot_prepare($vmid, $snapname, $save_vmstate, $comment);

    $save_vmstate = 0 if !$snap->{vmstate};

    my $conf = $class->load_config($vmid);

    my ($running, $freezefs) = $class->__snapshot_check_freeze_needed($vmid, $conf, $snap->{vmstate});

    my $drivehash = {};

    eval {
	if ($freezefs) {
	    $class->__snapshot_freeze($vmid, 0);
	}

	$class->__snapshot_create_vol_snapshots_hook($vmid, $snap, $running, "before");

	$class->__snapshot_foreach_volume($snap, sub {
	    my ($vs, $volume) = @_;

	    $class->__snapshot_create_vol_snapshot($vmid, $vs, $volume, $snapname);
	    $drivehash->{$vs} = 1;
	});
    };
    my $err = $@;

    if ($running) {
	$class->__snapshot_create_vol_snapshots_hook($vmid, $snap, $running, "after");
	if ($freezefs) {
	    $class->__snapshot_freeze($vmid, 1);
	}
	$class->__snapshot_create_vol_snapshots_hook($vmid, $snap, $running, "after-unfreeze");
    }

    if ($err) {
	warn "snapshot create failed: starting cleanup\n";
	eval { $class->snapshot_delete($vmid, $snapname, 1, $drivehash); };
	warn "$@" if $@;
	die "$err\n";
    }

    $class->__snapshot_commit($vmid, $snapname);
}

# Deletes a snapshot.
# Note: $drivehash is only set when called from snapshot_create.
sub snapshot_delete {
    my ($class, $vmid, $snapname, $force, $drivehash) = @_;

    my $prepare = 1;

    my $snap;
    my $unused = [];

    my $unlink_parent = sub {
	my ($confref, $new_parent) = @_;

	if ($confref->{parent} && $confref->{parent} eq $snapname) {
	    if ($new_parent) {
		$confref->{parent} = $new_parent;
	    } else {
		delete $confref->{parent};
	    }
	}
    };

    my $updatefn =  sub {
	my ($remove_drive) = @_;

	my $conf = $class->load_config($vmid);

	if (!$drivehash) {
	    $class->check_lock($conf);
	    die "you can't delete a snapshot if vm is a template\n"
		if $class->is_template($conf);
	}

	$snap = $conf->{snapshots}->{$snapname};

	die "snapshot '$snapname' does not exist\n" if !defined($snap);

	# remove parent refs
	if (!$prepare) {
	    &$unlink_parent($conf, $snap->{parent});
	    foreach my $sn (keys %{$conf->{snapshots}}) {
		next if $sn eq $snapname;
		&$unlink_parent($conf->{snapshots}->{$sn}, $snap->{parent});
	    }
	}

	if ($remove_drive) {
	    $class->__snapshot_delete_remove_drive($snap, $remove_drive);
	}

	if ($prepare) {
	    $snap->{snapstate} = 'delete';
	} else {
	    delete $conf->{snapshots}->{$snapname};
	    delete $conf->{lock} if $drivehash;
	    foreach my $volid (@$unused) {
		$class->add_unused_volume($conf, $volid);
	    }
	}

	$class->write_config($vmid, $conf);
    };

    $class->lock_config($vmid, $updatefn);

    # now remove vmstate file
    if ($snap->{vmstate}) {
	$class->__snapshot_delete_vmstate_file($snap, $force);

	# save changes (remove vmstate from snapshot)
	$class->lock_config($vmid, $updatefn, 'vmstate') if !$force;
    };

    # now remove all volume snapshots
    $class->__snapshot_foreach_volume($snap, sub {
	my ($vs, $volume) = @_;

	return if $snapname eq 'vzdump' && $vs ne 'rootfs' && !$volume->{backup};
	if (!$drivehash || $drivehash->{$vs}) {
	    eval { $class->__snapshot_delete_vol_snapshot($vmid, $vs, $volume, $snapname, $unused); };
	    if (my $err = $@) {
		die $err if !$force;
		warn $err;
	    }
	}

	# save changes (remove mp from snapshot)
	$class->lock_config($vmid, $updatefn, $vs) if !$force;
    });

    # now cleanup config
    $prepare = 0;
    $class->lock_config($vmid, $updatefn);
}

# Rolls back to a given snapshot.
sub snapshot_rollback {
    my ($class, $vmid, $snapname) = @_;

    my $prepare = 1;

    my $storecfg = PVE::Storage::config();

    my $conf = $class->load_config($vmid);

    my $get_snapshot_config = sub {

	die "you can't rollback if vm is a template\n" if $class->is_template($conf);

	my $res = $conf->{snapshots}->{$snapname};

	die "snapshot '$snapname' does not exist\n" if !defined($res);

	return $res;
    };

    my $snap = &$get_snapshot_config();

    $class->__snapshot_foreach_volume($snap, sub {
	my ($vs, $volume) = @_;

	$class->__snapshot_rollback_vol_possible($volume, $snapname);
    });

    my $updatefn = sub {

	$conf = $class->load_config($vmid);

	$snap = &$get_snapshot_config();

	die "unable to rollback to incomplete snapshot (snapstate = $snap->{snapstate})\n"
	    if $snap->{snapstate};

	if ($prepare) {
	    $class->check_lock($conf);
	    $class->__snapshot_rollback_vm_stop($vmid);
	}

	die "unable to rollback vm $vmid: vm is running\n"
	    if $class->__snapshot_check_running($vmid);

	if ($prepare) {
	    $conf->{lock} = 'rollback';
	} else {
	    die "got wrong lock\n" if !($conf->{lock} && $conf->{lock} eq 'rollback');
	    delete $conf->{lock};
	}

	# machine only relevant for Qemu
	my $forcemachine;

	if (!$prepare) {
	    my $has_machine_config = defined($conf->{machine});

	    # copy snapshot config to current config
	    $conf = $class->__snapshot_apply_config($conf, $snap);
	    $conf->{parent} = $snapname;

	    # Note: old code did not store 'machine', so we try to be smart
	    # and guess the snapshot was generated with kvm 1.4 (pc-i440fx-1.4).
	    $forcemachine = $conf->{machine} || 'pc-i440fx-1.4';
	    # we remove the 'machine' configuration if not explicitly specified
	    # in the original config.
	    delete $conf->{machine} if $snap->{vmstate} && !$has_machine_config;
	}

	$class->write_config($vmid, $conf);

	if (!$prepare && $snap->{vmstate}) {
	    $class->__snapshot_rollback_vm_start($vmid, $snap->{vmstate}, $forcemachine);
	}
    };

    $class->lock_config($vmid, $updatefn);

    $class->__snapshot_foreach_volume($snap, sub {
	my ($vs, $volume) = @_;

	$class->__snapshot_rollback_vol_rollback($volume, $snapname);
    });

    $prepare = 0;
    $class->lock_config($vmid, $updatefn);
}

1;
