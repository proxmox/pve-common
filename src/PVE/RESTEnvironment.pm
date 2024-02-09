package PVE::RESTEnvironment;

# NOTE: you can/should provide your own specialice class, and
# use this a bas class (as example see PVE::RPCEnvironment).

# we use this singleton class to pass RPC related environment values

use strict;
use warnings;

use Exporter qw(import);
use Fcntl qw(:flock);
use IO::File;
use IO::Handle;
use IO::Select;
use POSIX qw(:sys_wait_h EINTR);
use AnyEvent;

use PVE::Exception qw(raise raise_perm_exc);
use PVE::INotify;
use PVE::ProcFSTools;
use PVE::SafeSyslog;
use PVE::Tools;

our @EXPORT_OK = qw(log_warn);

my $rest_env;

# save $SIG{CHLD} handler implementation.
# simply set $SIG{CHLD} = $worker_reaper;
# and register forked processes with &$register_worker(pid)
# Note: using $SIG{CHLD} = 'IGNORE' or $SIG{CHLD} = sub { wait (); } or ...
# has serious side effects, because perls built in system() and open()
# functions can't get the correct exit status of a child. So we can't use
# that (also see perlipc)

my $WORKER_PIDS;
my $WORKER_FLAG = 0;

my $log_task_result = sub {
    my ($upid, $user, $status) = @_;

    return if !$rest_env;

    my $msg = 'successful';
    my $pri = 'info';
    if ($status != 0) {
	my $ec = $status >> 8;
	my $ic = $status & 255;
	$msg = $ec ? "failed ($ec)" : "interrupted ($ic)";
	$pri = 'err';
    }

    my $tlist = $rest_env->active_workers($upid);
    eval { $rest_env->broadcast_tasklist($tlist); };
    syslog('err', $@) if $@;

    my $task;
    foreach my $t (@$tlist) {
	if ($t->{upid} eq $upid) {
	    $task = $t;
	    last;
	}
    }
    if ($task && $task->{status}) {
	$msg = $task->{status};
    }

    $rest_env->log_cluster_msg($pri, $user, "end task $upid $msg");
};

my $worker_reaper = sub {
    local $!; local $?;
    foreach my $pid (keys %$WORKER_PIDS) {
        my $waitpid = waitpid ($pid, WNOHANG);
        if (defined($waitpid) && ($waitpid == $pid)) {
	    my $info = $WORKER_PIDS->{$pid};
	    if ($info && $info->{upid} && $info->{user}) {
		&$log_task_result($info->{upid}, $info->{user}, $?);
	    }
            delete ($WORKER_PIDS->{$pid});
	}
    }
};

my $register_worker = sub {
    my ($pid, $user, $upid) = @_;

    return if !$pid;

    # do not register if already finished
    my $waitpid = waitpid ($pid, WNOHANG);
    if (defined($waitpid) && ($waitpid == $pid)) {
	delete ($WORKER_PIDS->{$pid});
	return;
    }

    $WORKER_PIDS->{$pid} = {
	user => $user,
	upid => $upid,
    };
};

# initialize environment - must be called once at program startup
sub init {
    my ($class, $type, %params) = @_;

    $class = ref($class) || $class;

    die "already initialized" if $rest_env;

    die "unknown environment type"
	if !$type || $type !~ m/^(cli|pub|priv|ha)$/;

    $SIG{CHLD} = sub {
	# when we're using AnyEvent, we have to postpone the call to worker_reaper, otherwise it
	# might interfere with running api calls
	if (defined($AnyEvent::MODEL)) {
	    AnyEvent::postpone { $worker_reaper->() };
	} else {
	    $worker_reaper->();
	}
    };

    # environment types
    # cli  ... command started fron command line
    # pub  ... access from public server (pveproxy)
    # priv ... access from private server (pvedaemon)
    # ha   ... access from HA resource manager agent (pve-ha-manager)

    my $self = {
	type => $type,
	warning_count => 0,
    };

    bless $self, $class;

    foreach my $p (keys %params) {
	if ($p eq 'atfork') {
	    $self->{$p} = $params{$p};
	} else {
	    die "unknown option '$p'";
	}
    }

    $rest_env = $self;

    my ($sysname, $nodename) = POSIX::uname();

    $nodename =~ s/\..*$//; # strip domain part, if any

    $self->{nodename} = $nodename;

    return $self;
};

# convenience function for command line tools
sub setup_default_cli_env {
    my ($class, $username) = @_;

    $class = ref($class) || $class;

    $username //= 'root@pam';

    PVE::INotify::inotify_init();

    my $rpcenv = $class->init('cli');
    $rpcenv->init_request();
    $rpcenv->set_language($ENV{LANG});
    $rpcenv->set_user($username);

    die "please run as root\n"
	if ($username eq 'root@pam') && ($> != 0);
}

# get the singleton
sub get {

    die "REST environment not initialized" if !$rest_env;

    return $rest_env;
}

sub set_client_ip {
    my ($self, $ip) = @_;

    $self->{client_ip} = $ip;
}

sub get_client_ip {
    my ($self) = @_;

    return $self->{client_ip};
}

sub set_result_attrib {
    my ($self, $key, $value) = @_;

    $self->{result_attributes}->{$key} = $value;
}

sub get_result_attrib {
    my ($self, $key) = @_;

    return $self->{result_attributes}->{$key};
}

sub set_language {
    my ($self, $lang) = @_;

    # fixme: initialize I18N

    $self->{language} = $lang;
}

sub get_language {
    my ($self) = @_;

    return $self->{language};
}

sub set_user {
    my ($self, $user) = @_;

    $self->{user} = $user;
}

sub get_user {
    my ($self, $noerr) = @_;

    return $self->{user} if defined($self->{user}) || $noerr;

    die "user name not set\n";
}

sub set_u2f_challenge {
    my ($self, $challenge) = @_;

    $self->{u2f_challenge} = $challenge;
}

sub get_u2f_challenge {
    my ($self, $noerr) = @_;

    return $self->{u2f_challenge} if defined($self->{u2f_challenge}) || $noerr;

    die "no active u2f challenge\n";
}

sub set_request_host {
    my ($self, $host) = @_;

    $self->{request_host} = $host;
}

sub get_request_host {
    my ($self, $noerr) = @_;

    return $self->{request_host} if defined($self->{request_host}) || $noerr;

    die "no hostname available in current environment\n";
}

sub is_worker {
    my ($class) = @_;

    return $WORKER_FLAG;
}

# read/update list of active workers.
#
# we move all finished tasks to the archive index, but keep active, and most recent tasks in the
# active file.
# $nocheck ... consider $new_upid still running (avoid that we try to read the result to early).
sub active_workers {
    my ($self, $new_upid, $nocheck) = @_;

    my $timeout = 10;

    my $res = PVE::Tools::lock_file("/var/log/pve/tasks/.active.lock", $timeout, sub {
	my $tasklist = PVE::INotify::read_file('active');

	my @ta;
	my $tlist = [];
	my $thash = {}; # only list task once

	my $check_task = sub {
	    my ($task, $running) = @_;

	    if ($running || PVE::ProcFSTools::check_process_running($task->{pid}, $task->{pstart})) {
		push @$tlist, $task;
	    } else {
		delete $task->{pid};
		push @ta, $task;
	    }
	    delete $task->{pstart};
	};

	foreach my $task (@$tasklist) {
	    my $upid = $task->{upid};
	    next if $thash->{$upid};
	    $thash->{$upid} = $task;
	    &$check_task($task);
	}

	if ($new_upid && !$thash->{$new_upid}) {
	    my $task = PVE::Tools::upid_decode($new_upid);
	    $task->{upid} = $new_upid;
	    $thash->{$new_upid} = $task;
	    &$check_task($task, $nocheck);
	}


	@ta = sort { $b->{starttime} <=> $a->{starttime} } @ta;

	my $save = defined($new_upid);

	foreach my $task (@ta) {
	    next if $task->{endtime};
	    $task->{endtime} = time();
	    $task->{status} = PVE::Tools::upid_read_status($task->{upid});
	    $save = 1;
	}

	my $archive = '';
	my @arlist = ();
	foreach my $task (@ta) {
	    if (!$task->{saved}) {
		$archive .= sprintf("%s %08X %s\n", $task->{upid}, $task->{endtime}, $task->{status});
		$save = 1;
		push @arlist, $task;
		$task->{saved} = 1;
	    }
	}

	if ($archive) {
	    my $size = 0;
	    my $filename = "/var/log/pve/tasks/index";
	    eval {
		my $fh = IO::File->new($filename, '>>', 0644) ||
		    die "unable to open file '$filename' - $!\n";
		PVE::Tools::safe_print($filename, $fh, $archive);
		$size = -s $fh;
		close($fh) ||
		    die "unable to close file '$filename' - $!\n";
	    };
	    my $err = $@;
	    if ($err) {
		syslog('err', $err);
		foreach my $task (@arlist) { # mark as not saved
		    $task->{saved} = 0;
		}
	    }
	    my $maxsize = 50000; # about 1000 entries
	    if ($size > $maxsize) {
		rename($filename, "$filename.1");
	    }
	}

	# we try to reduce the amount of data list all running tasks and task and a few others
	my $MAX_FINISHED = 25;
	my $max = $MAX_FINISHED - scalar(@$tlist);
        foreach my $task (@ta) {
	    last if $max <= 0;
	    push @$tlist, $task;
	    $max--;
	}

	PVE::INotify::write_file('active', $tlist) if $save;

	return $tlist;
    });
    die $@ if $@;

    return $res;
}

my $kill_process_group = sub {
    my ($pid, $pstart) = @_;

    # send kill to process group (negative pid)
    my $kpid = -$pid;

    # always send signal to all pgrp members
    kill(15, $kpid); # send TERM signal

    # give max 5 seconds to shut down
    for (my $i = 0; $i < 5; $i++) {
	return if !PVE::ProcFSTools::check_process_running($pid, $pstart);
	sleep (1);
    }

    # to be sure
    kill(9, $kpid);
};

sub check_worker {
    my ($self, $upid, $killit) = @_;

    my $task = PVE::Tools::upid_decode($upid);

    my $running = PVE::ProcFSTools::check_process_running($task->{pid}, $task->{pstart});

    return 0 if !$running;

    if ($killit) {
	&$kill_process_group($task->{pid});
	return 0;
    }

    return 1;
}

# acts almost as tee: writes an output both to STDOUT and a task log,
# we differ as we're worker aware and look also at the childs control pipe,
# so we know if the function could be executed successfully or not.
my $tee_worker = sub {
    my ($childfd, $ctrlfd, $taskfh, $cpid) = @_;

    eval {
	my $int_count = 0;
	local $SIG{INT} = local $SIG{QUIT} = local $SIG{TERM} = sub {
	    # always send signal to all pgrp members
	    my $kpid = -$cpid;
	    if ($int_count < 3) {
		kill(15, $kpid); # send TERM signal
	    } else {
		kill(9, $kpid); # send KILL signal
	    }
	    $int_count++;
	};
	local $SIG{PIPE} = sub { die "broken pipe\n"; };

	my $select = IO::Select->new();
	my $fh = IO::Handle->new_from_fd($childfd, 'r');
	$select->add($fh);

	my $readbuf = '';
	my $count;
	while ($select->count) {
	    my @handles = $select->can_read(1);
	    if (scalar(@handles)) {
		my $count = sysread ($handles[0], $readbuf, 4096);
		if (!defined ($count)) {
		    my $err = $!;
		    die "sync pipe read error: $err\n";
		}
		last if $count == 0; # eof

		print $readbuf;
		select->flush();

		print $taskfh $readbuf;
		$taskfh->flush();
	    } else {
		# some commands daemonize without closing stdout
		last if !PVE::ProcFSTools::check_process_running($cpid);
	    }
	}

	POSIX::read($ctrlfd, $readbuf, 4096);
	if ($readbuf =~ m/^TASK OK\n?$/) {
	    # skip printing to stdout
	    print $taskfh $readbuf;
	} elsif ($readbuf =~ m/^TASK ERROR: (.*)\n?$/) {
	    print STDERR "$1\n";
	    print $taskfh "\n$readbuf"; # ensure start on new line for webUI
	} elsif ($readbuf =~ m/^TASK WARNINGS: (\d+)\n?$/) {
	    print STDERR "Task finished with $1 warning(s)!\n";
	    print $taskfh "\n$readbuf"; # ensure start on new line for webUI
	} else {
	    die "got unexpected control message: $readbuf\n";
	}
	$taskfh->flush();
    };
    my $err = $@;

    POSIX::close($childfd);
    POSIX::close($ctrlfd);

    if ($err) {
	$err =~ s/\n/ /mg;
	print STDERR "$err\n";
	print $taskfh "TASK ERROR: $err\n";
    }
};

# start long running workers
# STDIN is redirected to /dev/null
# STDOUT,STDERR are redirected to the filename returned by upid_decode
# NOTE: we simulate running in foreground if ($self->{type} eq 'cli')
sub fork_worker {
    my ($self, $dtype, $id, $user, $function, $background) = @_;

    $dtype = 'unknown' if !defined ($dtype);
    $id = '' if !defined ($id);

    # note: below is only used for the task log entry
    $user = $self->get_user(1) // 'root@pam' if !defined($user);

    my $sync = ($self->{type} eq 'cli' && !$background) ? 1 : 0;

    local $SIG{INT} =
	local $SIG{QUIT} =
	local $SIG{PIPE} =
	local $SIG{TERM} = 'IGNORE';

    my $starttime = time ();

    my @psync = POSIX::pipe();
    my @csync = POSIX::pipe();
    my @ctrlfd = $sync ? POSIX::pipe() : ();

    my $node = $self->{nodename};

    my $cpid = fork();
    die "unable to fork worker - $!" if !defined($cpid);

    my $workerpuid = $cpid ? $cpid : $$;

    my $pstart = PVE::ProcFSTools::read_proc_starttime($workerpuid) ||
	die "unable to read process start time";

    my $upid = PVE::Tools::upid_encode ({
	node => $node, pid => $workerpuid, pstart => $pstart,
	starttime => $starttime, type => $dtype, id => $id, user => $user });

    my $outfh;

    if (!$cpid) { # child

	$0 = "task $upid";
	$WORKER_FLAG = 1;

	$SIG{INT} = $SIG{QUIT} = $SIG{TERM} = sub { die "received interrupt\n"; };

	$SIG{CHLD} = $SIG{PIPE} = 'DEFAULT';
	$SIG{TTOU} = 'IGNORE';

	my $ppgid;
	# set session/process group allows to kill the process group
	if ($sync && -t STDIN) {
	    # some sync'ed workers operate on the tty but setsid sessions lose
	    # the tty, so just create a new pgroup and give it the tty
	    $ppgid = POSIX::getpgrp() or die "failed to get old pgid: $!\n";
	    POSIX::setpgid(0, 0) or die "failed to setpgid: $!\n";
	    POSIX::tcsetpgrp(fileno(STDIN), $$) or die "failed to tcsetpgrp: $!\n";
	} else {
	    POSIX::setsid();
	}

	POSIX::close ($psync[0]);
	POSIX::close ($ctrlfd[0]) if $sync;
	POSIX::close ($csync[1]);

	$outfh = $sync ? $psync[1] : undef;
	my $resfh = $sync ? $ctrlfd[1] : undef;

	eval {
	    PVE::INotify::inotify_close();

	    if (my $atfork = $self->{atfork}) {
		&$atfork();
	    }

	    # same algorithm as used inside SA
	    # STDIN = /dev/null
	    my $fd = fileno (STDIN);

	    if (!$sync) {
		close STDIN;
		POSIX::close(0) if $fd != 0;

		open(STDIN, '<', '/dev/null') or die "unable to redirect STDIN - $!";

		$outfh = PVE::Tools::upid_open($upid);
		$resfh = fileno($outfh);
	    }


	    # redirect STDOUT
	    $fd = fileno(STDOUT);
	    close STDOUT;
	    POSIX::close (1) if $fd != 1;

	    open(STDOUT, ">&", $outfh) or die "unable to redirect STDOUT - $!";

	    STDOUT->autoflush (1);

	    #  redirect STDERR to STDOUT
	    $fd = fileno (STDERR);
	    close STDERR;
	    POSIX::close(2) if $fd != 2;

	    open(STDERR, '>&', '1') or die "unable to redirect STDERR - $!";

	    STDERR->autoflush(1);
	};
	if (my $err = $@) {
	    my $msg =  "ERROR: $err";
	    POSIX::write($psync[1], $msg, length ($msg));
	    POSIX::close($psync[1]);
	    POSIX::_exit(1);
	    kill(-9, $$);
	}

	# sync with parent (signal that we are ready)
	POSIX::write($psync[1], $upid, length ($upid));
	POSIX::close($psync[1]) if !$sync; # don't need output pipe if async

	eval {
	    my $readbuf = '';
	    # sync with parent (wait until parent is ready)
	    POSIX::read($csync[0], $readbuf, 4096);
	    die "parent setup error\n" if $readbuf ne 'OK';

	    if ($self->{type} eq 'ha') {
		print "task started by HA resource agent\n";
	    }
	    &$function($upid);
	};
	my ($msg, $exitcode);
	my $err = $@;
	if ($err) {
	    chomp $err;
	    $err =~ s/\n/ /mg;
	    syslog('err', $err);
	    $msg = "TASK ERROR: $err\n";
	    $exitcode = -1;
	} elsif (my $warnings = $self->{warning_count}) {
	    $msg = "TASK WARNINGS: $warnings\n";
	    $exitcode = 0;
	} else {
	    $msg = "TASK OK\n";
	    $exitcode = 0;
	}
	POSIX::write($resfh, $msg, length($msg));

	if ($sync) {
	    POSIX::close($resfh);
	    if ( -t STDIN) {
		POSIX::tcsetpgrp(fileno(STDIN), $ppgid) or
		    die "failed to tcsetpgrp to parent: $!\n";
	    }
	}
	POSIX::_exit($exitcode);
	kill(-9, $$); # not really needed, just to be sure
    }

    # parent

    POSIX::close ($psync[1]);
    POSIX::close ($ctrlfd[1]) if $sync;
    POSIX::close ($csync[0]);

    my $readbuf = '';
    # sync with child (wait until child starts)
    POSIX::read($psync[0], $readbuf, 4096);

    if (!$sync) {
	POSIX::close($psync[0]);
	&$register_worker($cpid, $user, $upid);
    } else {
	chomp $readbuf;
    }

    eval {
	die "got no worker upid - start worker failed\n" if !$readbuf;

	if ($readbuf =~ m/^ERROR:\s*(.+)$/m) {
	    die "starting worker failed: $1\n";
	}

	if ($readbuf ne $upid) {
	    die "got strange worker upid ('$readbuf' != '$upid') - start worker failed\n";
	}

	if ($sync) {
	    $outfh = PVE::Tools::upid_open($upid);
	}
    };
    my $err = $@;

    if (!$err) {
	my $msg = 'OK';
	POSIX::write($csync[1], $msg, length ($msg));
	POSIX::close($csync[1]);

    } else {
	POSIX::close($csync[1]);
	kill(-9, $cpid); # make sure it gets killed
	die $err;
    }

    $self->log_cluster_msg('info', $user, "starting task $upid");

    my $tlist = $self->active_workers($upid, $sync);
    eval { $self->broadcast_tasklist($tlist); };
    syslog('err', $@) if $@;

    my $res = 0;

    if ($sync) {

	$tee_worker->($psync[0], $ctrlfd[0], $outfh, $cpid);

	&$kill_process_group($cpid, $pstart); # make sure it gets killed

	close($outfh);

	waitpid($cpid, 0);
	$res = $?;
	&$log_task_result($upid, $user, $res);
    }

    return wantarray ? ($upid, $res) : $upid;
}

sub log_warn {
    my ($message) = @_;

    if ($rest_env) {
	$rest_env->warn($message);
    } else {
	chomp($message);
	syslog('warning', "%s", $message);
	print STDERR "WARN: $message\n";
    }
}

sub warn {
    my ($self, $message) = @_;

    chomp($message);

    syslog('warning', "%s", $message);
    print STDERR "WARN: $message\n";

    $self->{warning_count}++;
}

# Abstract function

sub log_cluster_msg {
    my ($self, $pri, $user, $msg) = @_;

    syslog($pri, "%s", $msg);

    # PVE::Cluster::log_msg($pri, $user, $msg);
}

sub broadcast_tasklist {
    my ($self, $tlist) = @_;

    # PVE::Cluster::broadcast_tasklist($tlist);
}

sub check_api2_permissions {
    my ($self, $perm, $username, $param) = @_;

    return 1 if !$username && $perm->{user} eq 'world';

    raise_perm_exc("user != null") if !$username;

    return 1 if $username eq 'root@pam';

    raise_perm_exc('user != root@pam') if !$perm;

    return 1 if $perm->{user} && $perm->{user} eq 'all';

    ##return $self->exec_api2_perm_check($perm->{check}, $username, $param)
    ##if $perm->{check};

    raise_perm_exc();
}

# init_request - should be called before each REST/CLI request
sub init_request {
    my ($self, %params) = @_;

    $self->{result_attributes} = {}

    # if you nedd more, implement in subclass
}

1;
