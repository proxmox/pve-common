package PVE::Daemon;

# Abstract class to implement Daemons
#
# Features:
# * lock and write PID file /var/run/$name.pid to make sure onyl
#   one instance is running.
# * correctly daemonize (redirect STDIN/STDOUT)
# * daemon restart (option 'restart_on_error')

use strict;
use warnings;
use PVE::SafeSyslog;
use PVE::INotify;

use POSIX ":sys_wait_h";
use Fcntl ':flock';
use Getopt::Long;
use Time::HiRes qw (gettimeofday);

use base qw(PVE::CLIHandler);

$SIG{'__WARN__'} = sub {
    my $err = $@;
    my $t = $_[0];
    chomp $t;
    print "$t\n";
    syslog('warning', "WARNING: %s", $t);
    $@ = $err;
};

$ENV{'PATH'} = '/sbin:/bin:/usr/sbin:/usr/bin';

my $daemon_initialized = 0; # we only allow one instance

my $lockpidfile = sub {
    my ($self) = @_;

    my $lkfn = $self->{pidfile} . ".lock";

    if (!open (FLCK, ">>$lkfn")) {
	my $msg = "can't aquire lock on file '$lkfn' - $!";
	syslog ('err', $msg);
	die "ERROR: $msg\n";
    }

    if (!flock (FLCK, LOCK_EX|LOCK_NB)) {
	close (FLCK);
        my $msg = "can't aquire lock '$lkfn' - $!";
	syslog ('err', $msg);
	die "ERROR: $msg\n";
    }
};

my $writepidfile = sub {
    my ($self) = @_;

    my $pidfile = $self->{pidfile};

    if (!open (PIDFH, ">$pidfile")) {
	my $msg = "can't open pid file '$pidfile' - $!";
	syslog ('err', $msg);
	die "ERROR: $msg\n";
    }
    print PIDFH "$$\n";
    close (PIDFH);
};

my $server_cleanup = sub {
    my ($self) = @_;

    unlink $self->{pidfile} . ".lock";
    unlink $self->{pidfile};
};

my $server_run = sub {
    my ($self, $debug) = @_;

    &$lockpidfile($self);

    # run in background
    my $spid;

    my $restart = $ENV{RESTART_PVE_DAEMON};

    delete $ENV{RESTART_PVE_DAEMON};

    $self->{debug} = 1 if $debug;

    $self->init();

    if (!$debug) {
	open STDIN,  '</dev/null' || die "can't read /dev/null";
	open STDOUT, '>/dev/null' || die "can't write /dev/null";
    }

    if (!$restart && !$debug) {
	PVE::INotify::inotify_close();
	$spid = fork();
	if (!defined ($spid)) {
	    my $msg =  "can't put server into background - fork failed";
	    syslog('err', $msg);
	    die "ERROR: $msg\n";
	} elsif ($spid) { # parent
	    exit (0);
	}
	PVE::INotify::inotify_init();
    }

    &$writepidfile($self);

    POSIX::setsid(); 

    if ($restart) {
	syslog('info' , "restarting server");
    } else {
	syslog('info' , "starting server");
    }

    open STDERR, '>&STDOUT' || die "can't close STDERR\n";

    $SIG{INT} = $SIG{TERM} = $SIG{QUIT} = sub {
	$SIG{INT} = 'DEFAULT';

	eval { $self->shutdown(); };
	warn $@ if $@;

	&$server_cleanup($self);
   };

    $SIG{HUP} = sub {
	eval { $self->hup(); };
	warn $@ if $@;
    };

    eval { $self->run() };
    my $err = $@;

    if ($err) {
	syslog ('err', "ERROR: $err");
	if (my $wait_time = $self->{restart_on_error}) {
	    $self->restart_daemon($wait_time);
	} else {
	    $self->exit_daemon(-1);
	}
    }

    $self->exit_daemon(0);
};

sub new {
    my ($this, $name, $cmdline, %params) = @_;

    die "please run as root\n" if $> != 0;

    die "missing name" if !$name;

    die "can't create more that one PVE::Daemon" if $daemon_initialized;
    $daemon_initialized = 1;

    PVE::INotify::inotify_init();

    initlog($name);

    my $class = ref($this) || $this;

    my $self = bless { name => $name }, $class;

    $self->{pidfile} = "/var/run/${name}.pid";

    $self->{nodename} = PVE::INotify::nodename();

    $self->{cmdline} = $cmdline;

    $0 = $name;

    foreach my $opt (keys %params) {
	my $value = $params{$opt};
	if ($opt eq 'restart_on_error') {
	    $self->{$opt} = $value;
	} elsif ($opt eq 'stop_wait_time') {
	    $self->{$opt} = $value;
	} else {
	    die "unknown option '$opt'";
	}
    }

    return $self;
}

sub exit_daemon {
    my ($self, $status) = @_;

    syslog("info", "server stopped");

    &$server_cleanup($self);

    exit($status);
}

sub restart_daemon {
    my ($self, $waittime) = @_;

    syslog('info', "server shutdown (restart)");

    $ENV{RESTART_PVE_DAEMON} = 1;

    sleep($waittime) if $waittime; # avoid high server load due to restarts

    PVE::INotify::inotify_close();

    exec (@{$self->{cmdline}});

    exit (-1); # never reached?
}

# please overwrite in subclass
# this is called at startup - before forking
sub init {
    my ($self) = @_;

}

# please overwrite in subclass
sub shutdown {
    my ($self) = @_;

    syslog('info' , "server closing");

    # wait for children
    1 while (waitpid(-1, POSIX::WNOHANG()) > 0);
}

# please overwrite in subclass
sub hup {
    my ($self) = @_;

    syslog('info' , "received signal HUP (restart)");
}

# please overwrite in subclass
sub run {
    my ($self) = @_;

    for (;;) { # forever
	syslog('info' , "server is running");
	sleep(5);
    }
}

sub start {
    my ($self, $debug) = @_;

    &$server_run($self, $debug);
}

sub running {
    my ($self) = @_;

    my $pid = int(PVE::Tools::file_read_firstline($self->{pidfile}) || 0);

    if ($pid) {
	my $res = PVE::ProcFSTools::check_process_running($pid) ? 1 : 0;
	return wantarray ? ($res, $pid) : $res;
    }

    return wantarray ? (0, 0) : 0;
}

sub stop {
    my ($self) = @_;

    my $pid = int(PVE::Tools::file_read_firstline($self->{pidfile}) || 0);
    return if !$pid;

    if (PVE::ProcFSTools::check_process_running($pid)) {
	kill(15, $pid); # send TERM signal
	# give some time
	my $wait_time = $self->{stop_wait_time} || 5;
	my $running = 1;
	for (my $i = 0; $i < $wait_time; $i++) {
	    $running = PVE::ProcFSTools::check_process_running($pid);
	    last if !$running;
	    sleep (1);
	}

	syslog('err', "server still running - send KILL") if $running;

	# to be sure
	kill(9, $pid);
	waitpid($pid, 0);
    }

    if (-f $self->{pidfile}) {
	# try to get the lock
	&$lockpidfile($self);
	&$server_cleanup($self);
    }
}

sub register_start_command {
    my ($self, $class, $description) = @_;

    $class->register_method({
	name => 'start',
	path => 'start',
	method => 'POST',
	description => $description || "Start the daemon.",
	parameters => {
	    additionalProperties => 0,
	    properties => {
		debug => {
		    description => "Debug mode - stay in foreground",
		    type => "boolean",
		    optional => 1,
		    default => 0,
		},
	    },
	},
	returns => { type => 'null' },

	code => sub {
	    my ($param) = @_;

	    $self->start($param->{debug});

	    return undef;
	}});  
}

sub register_restart_command {
    my ($self, $class, $description) = @_;

    $class->register_method({
	name => 'restart',
	path => 'restart',
	method => 'POST',
	description => $description || "Restart the daemon (or start if not running).",
	parameters => {
	    additionalProperties => 0,
	    properties => {},
	},
	returns => { type => 'null' },

	code => sub {
	    my ($param) = @_;

	    if (my $restart = $ENV{RESTART_PVE_DAEMON}) {
		$self->start();
	    } else {
		my ($running, $pid) = $self->running(); 
		if (!$running) {
		    $self->start();
		} else {
		    kill(1, $pid);
		}
	    }

	    return undef;
	}});		   
}

sub register_stop_command {
    my ($self, $class, $description) = @_;

    $class->register_method({
	name => 'stop',
	path => 'stop',
	method => 'POST',
	description => $description || "Stop the daemon.",
	parameters => {
	    additionalProperties => 0,
	    properties => {},
	},
	returns => { type => 'null' },

	code => sub {
	    my ($param) = @_;
	    
	    $self->stop();

	    return undef;
	}});		   
}

sub register_status_command {
    my ($self, $class, $description) = @_;

    $class->register_method({
	name => 'status',
	path => 'status',
	method => 'GET',
	description => "Get daemon status.",
	parameters => {
	    additionalProperties => 0,
	    properties => {},
	},
	returns => { 
	    type => 'string',
	    enum => ['stopped', 'running'],
	},
	code => sub {
	    my ($param) = @_;

	    return $self->running() ? 'running' : 'stopped';
	}});
}

1;

