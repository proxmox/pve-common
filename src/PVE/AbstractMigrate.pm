package PVE::AbstractMigrate;

use strict;
use warnings;
use POSIX qw(strftime);
use PVE::Tools;

my $msg2text = sub {
    my ($level, $msg) = @_;

    chomp $msg;

    return '' if !$msg;

    my $res = '';

    my $tstr = strftime("%b %d %H:%M:%S", localtime);

    foreach my $line (split (/\n/, $msg)) {
	if ($level eq 'err') {
	    $res .= "$tstr ERROR: $line\n";
	} else {
	    $res .= "$tstr $line\n";
	}
    }

    return $res;
};

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    return if !$msg;

    print &$msg2text($level, $msg);
}

sub cmd {
    my ($self, $cmd, %param) = @_;

    my $logfunc = sub {
	my $line = shift;
	$self->log('info', $line);
    };

    $self->log('info', "# " . PVE::Tools::cmd2string($cmd));

    PVE::Tools::run_command($cmd, %param, outfunc => $logfunc, errfunc => $logfunc);
}

my $run_command_quiet_full = sub {
    my ($self, $cmd, $logerr, %param) = @_;

    my $log = '';
    my $logfunc = sub {
	my $line = shift;
	$log .= &$msg2text('info', $line);;
    };

    eval { PVE::Tools::run_command($cmd, %param, outfunc => $logfunc, errfunc => $logfunc); };
    if (my $err = $@) {
	$self->log('info', "# " . PVE::Tools::cmd2string($cmd));
	print $log;
	if ($logerr) {
	    $self->{errors} = 1;
	    $self->log('err', $err);
	} else {
	    die $err;
	}
    }
};

sub cmd_quiet {
    my ($self, $cmd, %param) = @_;
    return &$run_command_quiet_full($self, $cmd, 0, %param);
}

sub cmd_logerr {
    my ($self, $cmd, %param) = @_;
    return &$run_command_quiet_full($self, $cmd, 1, %param);
}

sub get_remote_migration_ip {
    my ($self) = @_;

    my $ip;

    my $cmd = [@{$self->{rem_ssh}}, 'pvecm', 'mtunnel', '--get_migration_ip'];

    push @$cmd, '--migration_network', $self->{opts}->{migration_network}
      if defined($self->{opts}->{migration_network});

    PVE::Tools::run_command($cmd, outfunc => sub {
	my $line = shift;

	if ($line =~ m/^ip: '($PVE::Tools::IPRE)'$/) {
	   $ip = $1;
	}
    });

    return $ip;
}

my $eval_int = sub {
    my ($self, $func, @param) = @_;

    eval {
	local $SIG{INT} = $SIG{TERM} = $SIG{QUIT} = $SIG{HUP} = sub {
	    $self->{delayed_interrupt} = 0;
	    die "interrupted by signal\n";
	};
	local $SIG{PIPE} = sub {
	    $self->{delayed_interrupt} = 0;
	    die "interrupted by signal\n";
	};

	my $di = $self->{delayed_interrupt};
	$self->{delayed_interrupt} = 0;

	die "interrupted by signal\n" if $di;

	&$func($self, @param);
    };
};

my @ssh_opts = ('-o', 'BatchMode=yes');
my @ssh_cmd = ('/usr/bin/ssh', @ssh_opts);
my @scp_cmd = ('/usr/bin/scp', @ssh_opts);
my @rsync_opts = ('-aHAX', '--delete', '--numeric-ids');
my @rsync_cmd = ('/usr/bin/rsync', @rsync_opts);

sub migrate {
    my ($class, $node, $nodeip, $vmid, $opts) = @_;

    $class = ref($class) || $class;

    my $self = {
	delayed_interrupt => 0,
	opts => $opts,
	vmid => $vmid,
	node => $node,
	nodeip => $nodeip,
	rsync_cmd => [ @rsync_cmd ],
	rem_ssh => [ @ssh_cmd, "root\@$nodeip" ],
	scp_cmd => [ @scp_cmd ],
    };

    $self = bless $self, $class;

    my $starttime = time();

    local $ENV{RSYNC_RSH} = join(' ', @ssh_cmd);

    local $SIG{INT} = $SIG{TERM} = $SIG{QUIT} = $SIG{HUP} = $SIG{PIPE} = sub {
	$self->log('err', "received interrupt - delayed");
	$self->{delayed_interrupt} = 1;
    };

    local $ENV{RSYNC_RSH} = join(' ', @ssh_cmd);
    
    # lock container during migration
    eval { $self->lock_vm($self->{vmid}, sub {

	$self->{running} = 0;
	&$eval_int($self, sub { $self->{running} = $self->prepare($self->{vmid}); });
	die $@ if $@;

	# get dedicated migration address from remote node, if set.
	# as a side effect this checks also if the other node can be accessed
	# through ssh and that it has quorum
	my $remote_migration_ip = $self->get_remote_migration_ip();

	if (defined($remote_migration_ip)) {
	    $nodeip = $remote_migration_ip;
	    $self->{nodeip} = $remote_migration_ip;
	    $self->{rem_ssh} = [ @ssh_cmd, "root\@$nodeip" ];

	    $self->log('info', "use dedicated network address for sending " .
	               "migration traffic ($self->{nodeip})");

	    # test if we can connect to new IP
	    my $cmd = [ @{$self->{rem_ssh}}, '/bin/true' ];
	    eval { $self->cmd_quiet($cmd); };
	    die "Can't connect to destination address ($self->{nodeip}) using " .
	        "public key authentication\n" if $@;
	}

	&$eval_int($self, sub { $self->phase1($self->{vmid}); });
	my $err = $@;
	if ($err) {
	    $self->log('err', $err);
	    eval { $self->phase1_cleanup($self->{vmid}, $err); };
	    if (my $tmperr = $@) {
		$self->log('err', $tmperr);
	    }
	    eval { $self->final_cleanup($self->{vmid}); };
	    if (my $tmperr = $@) {
		$self->log('err', $tmperr);
	    }
	    die $err;
	}

	# vm is now owned by other node
	# Note: there is no VM config file on the local node anymore

	if ($self->{running}) {

	    &$eval_int($self, sub { $self->phase2($self->{vmid}); });
	    my $phase2err = $@;
	    if ($phase2err) {
		$self->{errors} = 1;
		$self->log('err', "online migrate failure - $phase2err");
	    }
	    eval { $self->phase2_cleanup($self->{vmid}, $phase2err); };
	    if (my $err = $@) {
		$self->log('err', $err);
		$self->{errors} = 1;
	    }
	}

	# phase3 (finalize) 
	&$eval_int($self, sub { $self->phase3($self->{vmid}); });
	my $phase3err = $@;
	if ($phase3err) {
	    $self->log('err', $phase3err);
	    $self->{errors} = 1;
	}
	eval { $self->phase3_cleanup($self->{vmid}, $phase3err); };
	if (my $err = $@) {
	    $self->log('err', $err);
	    $self->{errors} = 1;
	}
	eval { $self->final_cleanup($self->{vmid}); };
	if (my $err = $@) {
	    $self->log('err', $err);
	    $self->{errors} = 1;
	}
    })};

    my $err = $@;

    my $delay = time() - $starttime;
    my $mins = int($delay/60);
    my $secs = $delay - $mins*60;
    my $hours =  int($mins/60);
    $mins = $mins - $hours*60;

    my $duration = sprintf "%02d:%02d:%02d", $hours, $mins, $secs;

    if ($err) {
	$self->log('err', "migration aborted (duration $duration): $err");
	die "migration aborted\n";
    }

    if ($self->{errors}) {
	$self->log('err', "migration finished with problems (duration $duration)");
	die "migration problems\n"
    }

    $self->log('info', "migration finished successfully (duration $duration)");
}

sub lock_vm {
    my ($self, $vmid, $code, @param) = @_;

    die "abstract method - implement me";
}

sub prepare {
    my ($self, $vmid) = @_;

    die "abstract method - implement me";

    # return $running;
}

# transfer all data and move VM config files
sub phase1 {
    my ($self, $vmid) = @_;
    die "abstract method - implement me";
}

# only called if there are errors in phase1
sub phase1_cleanup {
    my ($self, $vmid, $err) = @_;
    die "abstract method - implement me";
}

# only called when VM is running and phase1 was successful
sub phase2 {
    my ($self, $vmid) = @_;
    die "abstract method - implement me";
}

# only called when VM is running and phase1 was successful
sub phase2_cleanup {
    my ($self, $vmid, $err) = @_;
};

#  only called when phase1 was successful
sub phase3 {
    my ($self, $vmid) = @_;
}

#  only called when phase1 was successful
sub phase3_cleanup {
    my ($self, $vmid, $err) = @_;
}

# final cleanup - always called
sub final_cleanup {
    my ($self, $vmid) = @_;
    die "abstract method - implement me";
}

1;
