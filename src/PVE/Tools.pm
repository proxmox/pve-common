package PVE::Tools;

use strict;
use warnings;

use Date::Format qw(time2str);
use Digest::MD5;
use Digest::SHA;
use Encode;
use Fcntl qw(:DEFAULT :flock);
use File::Basename;
use File::Path qw(make_path);
use Filesys::Df (); # don't overwrite our df()
use IO::Dir;
use IO::File;
use IO::Handle;
use IO::Pipe;
use IO::Select;
use IO::Socket::IP;
use IPC::Open3;
use JSON;
use POSIX qw(EINTR EEXIST EOPNOTSUPP);
use Scalar::Util 'weaken';
use Socket qw(AF_INET AF_INET6 AI_ALL AI_V4MAPPED AI_CANONNAME SOCK_DGRAM IPPROTO_TCP);
use String::ShellQuote;
use Text::ParseWords;
use Time::HiRes qw(usleep gettimeofday tv_interval alarm);
use URI::Escape;
use base 'Exporter';

use PVE::Syscall;

# avoid warning when parsing long hex values with hex()
no warnings 'portable'; # Support for 64-bit ints required

our @EXPORT_OK = qw(
$IPV6RE
$IPV4RE
lock_file
lock_file_full
run_command
file_set_contents
file_get_contents
file_read_firstline
dir_glob_regex
dir_glob_foreach
split_list
template_replace
safe_print
trim
extract_param
extract_sensitive_params
file_copy
get_host_arch
O_PATH
O_TMPFILE
AT_EMPTY_PATH
AT_FDCWD
CLONE_NEWNS
CLONE_NEWUTS
CLONE_NEWIPC
CLONE_NEWUSER
CLONE_NEWPID
CLONE_NEWNET
);

my $pvelogdir = "/var/log/pve";
my $pvetaskdir = "$pvelogdir/tasks";

mkdir $pvelogdir;
mkdir $pvetaskdir;

my $IPV4OCTET = "(?:25[0-5]|(?:2[0-4]|1[0-9]|[1-9])?[0-9])";
our $IPV4RE = "(?:(?:$IPV4OCTET\\.){3}$IPV4OCTET)";
my $IPV6H16 = "(?:[0-9a-fA-F]{1,4})";
my $IPV6LS32 = "(?:(?:$IPV4RE|$IPV6H16:$IPV6H16))";

our $IPV6RE = "(?:" .
    "(?:(?:" .                             "(?:$IPV6H16:){6})$IPV6LS32)|" .
    "(?:(?:" .                           "::(?:$IPV6H16:){5})$IPV6LS32)|" .
    "(?:(?:(?:" .              "$IPV6H16)?::(?:$IPV6H16:){4})$IPV6LS32)|" .
    "(?:(?:(?:(?:$IPV6H16:){0,1}$IPV6H16)?::(?:$IPV6H16:){3})$IPV6LS32)|" .
    "(?:(?:(?:(?:$IPV6H16:){0,2}$IPV6H16)?::(?:$IPV6H16:){2})$IPV6LS32)|" .
    "(?:(?:(?:(?:$IPV6H16:){0,3}$IPV6H16)?::(?:$IPV6H16:){1})$IPV6LS32)|" .
    "(?:(?:(?:(?:$IPV6H16:){0,4}$IPV6H16)?::" .           ")$IPV6LS32)|" .
    "(?:(?:(?:(?:$IPV6H16:){0,5}$IPV6H16)?::" .            ")$IPV6H16)|" .
    "(?:(?:(?:(?:$IPV6H16:){0,6}$IPV6H16)?::" .                    ")))";

our $IPRE = "(?:$IPV4RE|$IPV6RE)";

our $EMAIL_USER_RE = qr/[\w\+\-\~]+(\.[\w\+\-\~]+)*/;
our $EMAIL_RE = qr/$EMAIL_USER_RE@[a-zA-Z0-9\-]+(\.[a-zA-Z0-9\-]+)*/;

use constant {CLONE_NEWNS   => 0x00020000,
              CLONE_NEWUTS  => 0x04000000,
              CLONE_NEWIPC  => 0x08000000,
              CLONE_NEWUSER => 0x10000000,
              CLONE_NEWPID  => 0x20000000,
              CLONE_NEWNET  => 0x40000000};

use constant {O_PATH    => 0x00200000,
              O_CLOEXEC => 0x00080000,
              O_TMPFILE => 0x00410000}; # This includes O_DIRECTORY

use constant {AT_EMPTY_PATH => 0x1000,
              AT_FDCWD => -100};

# from <linux/fs.h>
use constant {RENAME_NOREPLACE => (1 << 0),
              RENAME_EXCHANGE  => (1 << 1),
              RENAME_WHITEOUT  => (1 << 2)};

sub run_with_timeout {
    my ($timeout, $code, @param) = @_;

    die "got timeout\n" if $timeout <= 0;

    my $prev_alarm = alarm 0; # suspend outer alarm early

    my $sigcount = 0;

    my $res;

    eval {
	local $SIG{ALRM} = sub { $sigcount++; die "got timeout\n"; };
	local $SIG{PIPE} = sub { $sigcount++; die "broken pipe\n" };
	local $SIG{__DIE__};   # see SA bug 4631

	alarm($timeout);

	eval { $res = &$code(@param); };

	alarm(0); # avoid race conditions

	die $@ if $@;
    };

    my $err = $@;

    alarm $prev_alarm;

    # this shouldn't happen anymore?
    die "unknown error" if $sigcount && !$err; # seems to happen sometimes

    die $err if $err;

    return $res;
}

# flock: we use one file handle per process, so lock file
# can be nested multiple times and succeeds for the same process.
#
# Since this is the only way we lock now and we don't have the old
# 'lock(); code(); unlock();' pattern anymore we do not actually need to
# count how deep we're nesting. Therefore this hash now stores a weak reference
# to a boolean telling us whether we already have a lock.

my $lock_handles =  {};

sub lock_file_full {
    my ($filename, $timeout, $shared, $code, @param) = @_;

    $timeout = 10 if !$timeout;

    my $mode = $shared ? LOCK_SH : LOCK_EX;

    my $lockhash = ($lock_handles->{$$} //= {});

    # Returns a locked file handle.
    my $get_locked_file = sub {
	my $fh = IO::File->new(">>$filename")
	    or die "can't open file - $!\n";

	if (!flock($fh, $mode|LOCK_NB)) {
	    print STDERR "trying to acquire lock...\n";
	    my $success;
	    while(1) {
		$success = flock($fh, $mode);
		# try again on EINTR (see bug #273)
		if ($success || ($! != EINTR)) {
		    last;
		}
	    }
	    if (!$success) {
		print STDERR " failed\n";
		die "can't acquire lock '$filename' - $!\n";
	    }
	    print STDERR " OK\n";
	}

	return $fh;
    };

    my $res;
    my $checkptr = $lockhash->{$filename};
    my $check = 0; # This must not go out of scope before running the code.
    my $local_fh; # This must stay local
    if (!$checkptr || !$$checkptr) {
	# We cannot create a weak reference in a single atomic step, so we first
	# create a false-value, then create a reference to it, then weaken it,
	# and after successfully locking the file we change the boolean value.
	#
	# The reason for this is that if an outer SIGALRM throws an exception
	# between creating the reference and weakening it, a subsequent call to
	# lock_file_full() will see a leftover full reference to a valid
	# variable. This variable must be 0 in order for said call to attempt to
	# lock the file anew.
	#
	# An externally triggered exception elsewhere in the code will cause the
	# weak reference to become 'undef', and since the file handle is only
	# stored in the local scope in $local_fh, the file will be closed by
	# perl's cleanup routines as well.
	#
	# This still assumes that an IO::File handle can properly deal with such
	# exceptions thrown during its own destruction, but that's up to perls
	# guts now.
	$lockhash->{$filename} = \$check;
	weaken $lockhash->{$filename};
	$local_fh = eval { run_with_timeout($timeout, $get_locked_file) };
	if ($@) {
	    $@ = "can't lock file '$filename' - $@";
	    return undef;
	}
	$check = 1;
    }
    $res = eval { &$code(@param); };
    return undef if $@;
    return $res;
}


sub lock_file {
    my ($filename, $timeout, $code, @param) = @_;

    return lock_file_full($filename, $timeout, 0, $code, @param);
}

sub file_set_contents {
    my ($filename, $data, $perm)  = @_;

    $perm = 0644 if !defined($perm);

    my $tmpname = "$filename.tmp.$$";

    eval {
	my ($fh, $tries) = (undef, 0);
	while (!$fh && $tries++ < 3) {
	    $fh = IO::File->new($tmpname, O_WRONLY|O_CREAT|O_EXCL, $perm);
	    if (!$fh && $! == EEXIST) {
		unlink($tmpname) or die "unable to delete old temp file: $!\n";
	    }
	}
	die "unable to open file '$tmpname' - $!\n" if !$fh;
	die "unable to write '$tmpname' - $!\n" unless print $fh $data;
	die "closing file '$tmpname' failed - $!\n" unless close $fh;
    };
    my $err = $@;

    if ($err) {
	unlink $tmpname;
	die $err;
    }

    if (!rename($tmpname, $filename)) {
	my $msg = "close (rename) atomic file '$filename' failed: $!\n";
	unlink $tmpname;
	die $msg;
    }
}

sub file_get_contents {
    my ($filename, $max) = @_;

    my $fh = IO::File->new($filename, "r") ||
	die "can't open '$filename' - $!\n";

    my $content = safe_read_from($fh, $max, 0, $filename);

    close $fh;

    return $content;
}

sub file_copy {
    my ($filename, $dst, $max, $perm) = @_;

    file_set_contents ($dst, file_get_contents($filename, $max), $perm);
}

sub file_read_firstline {
    my ($filename) = @_;

    my $fh = IO::File->new ($filename, "r");
    return undef if !$fh;
    my $res = <$fh>;
    chomp $res if $res;
    $fh->close;
    return $res;
}

sub safe_read_from {
    my ($fh, $max, $oneline, $filename) = @_;

    # pmxcfs file size limit
    $max = 1024 * 1024 if !$max;

    my $subject = defined($filename) ? "file '$filename'" : 'input';

    my $br = 0;
    my $input = '';
    my $count;
    while ($count = sysread($fh, $input, 8192, $br)) {
	$br += $count;
	die "$subject too long - aborting\n" if $br > $max;
	if ($oneline && $input =~ m/^(.*)\n/) {
	    $input = $1;
	    last;
	}
    }
    die "unable to read $subject - $!\n" if !defined($count);

    return $input;
}

# The $cmd parameter can be:
#  -) a string
#    This is generally executed by passing it to the shell with the -c option.
#    However, it can be executed in one of two ways, depending on whether
#    there's a pipe involved:
#      *) with pipe: passed explicitly to bash -c, prefixed with:
#          set -o pipefail &&
#      *) without a pipe: passed to perl's open3 which uses 'sh -c'
#      (Note that this may result in two different syntax requirements!)
#      FIXME?
#  -) an array of arguments (strings)
#    Will be executed without interference from a shell. (Parameters are passed
#    as is, no escape sequences of strings will be touched.)
#  -) an array of arrays
#    Each array represents a command, and each command's output is piped into
#    the following command's standard input.
#    For this a shell command string is created with pipe symbols between each
#    command.
#    Each command is a list of strings meant to end up in the final command
#    unchanged. In order to achieve this, every argument is shell-quoted.
#    Quoting can be disabled for a particular argument by turning it into a
#    reference, this allows inserting arbitrary shell options.
#    For instance: the $cmd [ [ 'echo', 'hello', \'>/dev/null' ] ] will not
#    produce any output, while the $cmd [ [ 'echo', 'hello', '>/dev/null' ] ]
#    will literally print: hello >/dev/null
sub run_command {
    my ($cmd, %param) = @_;

    my $old_umask;
    my $cmdstr;

    if (my $ref = ref($cmd)) {
	if (ref($cmd->[0])) {
	    $cmdstr = 'set -o pipefail && ';
	    my $pipe = '';
	    foreach my $command (@$cmd) {
		# concatenate quoted parameters
		# strings which are passed by reference are NOT shell quoted
		$cmdstr .= $pipe .  join(' ', map { ref($_) ? $$_ : shellquote($_) } @$command);
		$pipe = ' | ';
	    }
	    $cmd = [ '/bin/bash', '-c', "$cmdstr" ];
	} else {
	    $cmdstr = cmd2string($cmd);
	}
    } else {
	$cmdstr = $cmd;
	if ($cmd =~ m/\|/) {
	    # see 'man bash' for option pipefail
	    $cmd = [ '/bin/bash', '-c', "set -o pipefail && $cmd" ];
	} else {
	    $cmd = [ $cmd ];
	}
    }

    my $errmsg;
    my $laststderr;
    my $timeout;
    my $oldtimeout;
    my $pid;
    my $exitcode = -1;

    my $outfunc;
    my $errfunc;
    my $logfunc;
    my $input;
    my $output;
    my $afterfork;
    my $noerr;
    my $keeplocale;
    my $quiet;

    eval {

	foreach my $p (keys %param) {
	    if ($p eq 'timeout') {
		$timeout = $param{$p};
	    } elsif ($p eq 'umask') {
		$old_umask = umask($param{$p});
	    } elsif ($p eq 'errmsg') {
		$errmsg = $param{$p};
	    } elsif ($p eq 'input') {
		$input = $param{$p};
	    } elsif ($p eq 'output') {
		$output = $param{$p};
	    } elsif ($p eq 'outfunc') {
		$outfunc = $param{$p};
	    } elsif ($p eq 'errfunc') {
		$errfunc = $param{$p};
	    } elsif ($p eq 'logfunc') {
		$logfunc = $param{$p};
	    } elsif ($p eq 'afterfork') {
		$afterfork = $param{$p};
	    } elsif ($p eq 'noerr') {
		$noerr = $param{$p};
	    } elsif ($p eq 'keeplocale') {
		$keeplocale = $param{$p};
	    } elsif ($p eq 'quiet') {
		$quiet = $param{$p};
	    } else {
		die "got unknown parameter '$p' for run_command\n";
	    }
	}

	if ($errmsg) {
	    my $origerrfunc = $errfunc;
	    $errfunc = sub {
		if ($laststderr) {
		    if ($origerrfunc) {
			&$origerrfunc("$laststderr\n");
		    } else {
			print STDERR "$laststderr\n" if $laststderr;
		    }
		}
		$laststderr = shift;
	    };
	}

	my $reader = $output && $output =~ m/^>&/ ? $output : IO::File->new();
	my $writer = $input && $input =~ m/^<&/ ? $input : IO::File->new();
	my $error  = IO::File->new();

	my $orig_pid = $$;

	eval {
	    local $ENV{LC_ALL} = 'C' if !$keeplocale;

	    # suppress LVM warnings like: "File descriptor 3 left open";
	    local $ENV{LVM_SUPPRESS_FD_WARNINGS} = "1";

	    $pid = open3($writer, $reader, $error, @$cmd) || die $!;

	    # if we pipe fron STDIN, open3 closes STDIN, so we get a perl warning like
	    # "Filehandle STDIN reopened as GENXYZ .. " as soon as we open a new file.
	    # to avoid that we open /dev/null
	    if (!ref($writer) && !defined(fileno(STDIN))) {
		POSIX::close(0);
		open(STDIN, '<', '/dev/null');
	    }
	};

	my $err = $@;

	# catch exec errors
	if ($orig_pid != $$) {
	    warn "ERROR: $err";
	    POSIX::_exit (1);
	    kill ('KILL', $$);
	}

	die $err if $err;

	local $SIG{ALRM} = sub { die "got timeout\n"; } if $timeout;
	$oldtimeout = alarm($timeout) if $timeout;

	&$afterfork() if $afterfork;

	if (ref($writer)) {
	    print $writer $input if defined $input;
	    close $writer;
	}

	my $select = IO::Select->new();
	$select->add($reader) if ref($reader);
	$select->add($error);

	my $outlog = '';
	my $errlog = '';

	my $starttime = time();

	while ($select->count) {
	    my @handles = $select->can_read(1);

	    foreach my $h (@handles) {
		my $buf = '';
		my $count = sysread ($h, $buf, 4096);
		if (!defined ($count)) {
		    my $err = $!;
		    kill (9, $pid);
		    waitpid ($pid, 0);
		    die $err;
		}
		$select->remove ($h) if !$count;
		if ($h eq $reader) {
		    if ($outfunc || $logfunc) {
			eval {
			    while ($buf =~ s/^([^\010\r\n]*)(?:\n|(?:\010)+|\r\n?)//) {
				my $line = $outlog . $1;
				$outlog = '';
				&$outfunc($line) if $outfunc;
				&$logfunc($line) if $logfunc;
			    }
			    $outlog .= $buf;
			};
			my $err = $@;
			if ($err) {
			    kill (9, $pid);
			    waitpid ($pid, 0);
			    die $err;
			}
		    } elsif (!$quiet) {
			print $buf;
			*STDOUT->flush();
		    }
		} elsif ($h eq $error) {
		    if ($errfunc || $logfunc) {
			eval {
			    while ($buf =~ s/^([^\010\r\n]*)(?:\n|(?:\010)+|\r\n?)//) {
				my $line = $errlog . $1;
				$errlog = '';
				&$errfunc($line) if $errfunc;
				&$logfunc($line) if $logfunc;
			    }
			    $errlog .= $buf;
			};
			my $err = $@;
			if ($err) {
			    kill (9, $pid);
			    waitpid ($pid, 0);
			    die $err;
			}
		    } elsif (!$quiet) {
			print STDERR $buf;
			*STDERR->flush();
		    }
		}
	    }
	}

	&$outfunc($outlog) if $outfunc && $outlog;
	&$logfunc($outlog) if $logfunc && $outlog;

	&$errfunc($errlog) if $errfunc && $errlog;
	&$logfunc($errlog) if $logfunc && $errlog;

	waitpid ($pid, 0);

	if ($? == -1) {
	    die "failed to execute\n";
	} elsif (my $sig = ($? & 127)) {
	    die "got signal $sig\n";
	} elsif ($exitcode = ($? >> 8)) {
	    if (!($exitcode == 24 && ($cmdstr =~ m|^(\S+/)?rsync\s|))) {
		if ($errmsg && $laststderr) {
		    my $lerr = $laststderr;
		    $laststderr = undef;
		    die "$lerr\n";
		}
		die "exit code $exitcode\n";
	    }
	}

        alarm(0);
    };

    my $err = $@;

    alarm(0);

    if ($errmsg && $laststderr) {
	&$errfunc(undef); # flush laststderr
    }

    umask ($old_umask) if defined($old_umask);

    alarm($oldtimeout) if $oldtimeout;

    if ($err) {
	if ($pid && ($err eq "got timeout\n")) {
	    kill (9, $pid);
	    waitpid ($pid, 0);
	    die "command '$cmdstr' failed: $err";
	}

	if ($errmsg) {
	    $err =~ s/^usermod:\s*// if $cmdstr =~ m|^(\S+/)?usermod\s|;
	    die "$errmsg: $err";
	} elsif(!$noerr) {
	    die "command '$cmdstr' failed: $err";
	}
    }

    return $exitcode;
}

# Run a command with a tcp socket as standard input.
sub pipe_socket_to_command  {
    my ($cmd, $ip, $port) = @_;

    my $params = {
	Listen => 1,
	ReuseAddr => 1,
	Proto => &Socket::IPPROTO_TCP,
	GetAddrInfoFlags => 0,
	LocalAddr => $ip,
	LocalPort => $port,
    };
    my $socket = IO::Socket::IP->new(%$params) or die "failed to open socket: $!\n";

    print "$ip\n$port\n"; # tell remote where to connect
    *STDOUT->flush();

    alarm 0;
    local $SIG{ALRM} = sub { die "timed out waiting for client\n" };
    alarm 30;
    my $client = $socket->accept; # Wait for a client
    alarm 0;
    close($socket);

    # We want that the command talks over the TCP socket and takes
    # ownership of it, so that when it closes it the connection is
    # terminated, so we need to be able to close the socket. So we
    # can't really use PVE::Tools::run_command().
    my $pid = fork() // die "fork failed: $!\n";
    if (!$pid) {
	POSIX::dup2(fileno($client), 0);
	POSIX::dup2(fileno($client), 1);
	close($client);
	exec {$cmd->[0]} @$cmd or do {
	    warn "exec failed: $!\n";
	    POSIX::_exit(1);
	};
    }

    close($client);
    if (waitpid($pid, 0) != $pid) {
	kill(15 => $pid); # if we got interrupted terminate the child
	my $count = 0;
	while (waitpid($pid, POSIX::WNOHANG) != $pid) {
	    usleep(100000);
	    $count++;
	    kill(9 => $pid), last if $count > 300; # 30 second timeout
	}
    }
    if (my $sig = ($? & 127)) {
	die "got signal $sig\n";
    } elsif (my $exitcode = ($? >> 8)) {
	die "exit code $exitcode\n";
    }

    return undef;
}

sub split_list {
    my $listtxt = shift // '';

    return split (/\0/, $listtxt) if $listtxt =~ m/\0/;

    $listtxt =~ s/[,;]/ /g;
    $listtxt =~ s/^\s+//;

    my @data = split (/\s+/, $listtxt);

    return @data;
}

sub trim {
    my $txt = shift;

    return $txt if !defined($txt);

    $txt =~ s/^\s+//;
    $txt =~ s/\s+$//;

    return $txt;
}

# simple uri templates like "/vms/{vmid}"
sub template_replace {
    my ($tmpl, $data) = @_;

    return $tmpl if !$tmpl;

    my $res = '';
    while ($tmpl =~ m/([^{]+)?(\{([^}]+)\})?/g) {
	$res .= $1 if $1;
	$res .= ($data->{$3} || '-') if $2;
    }
    return $res;
}

sub safe_print {
    my ($filename, $fh, $data) = @_;

    return if !$data;

    my $res = print $fh $data;

    die "write to '$filename' failed\n" if !$res;
}

sub debmirrors {

    return {
	'at' => 'ftp.at.debian.org',
	'au' => 'ftp.au.debian.org',
	'be' => 'ftp.be.debian.org',
	'bg' => 'ftp.bg.debian.org',
	'br' => 'ftp.br.debian.org',
	'ca' => 'ftp.ca.debian.org',
	'ch' => 'ftp.ch.debian.org',
	'cl' => 'ftp.cl.debian.org',
	'cz' => 'ftp.cz.debian.org',
	'de' => 'ftp.de.debian.org',
	'dk' => 'ftp.dk.debian.org',
	'ee' => 'ftp.ee.debian.org',
	'es' => 'ftp.es.debian.org',
	'fi' => 'ftp.fi.debian.org',
	'fr' => 'ftp.fr.debian.org',
	'gr' => 'ftp.gr.debian.org',
	'hk' => 'ftp.hk.debian.org',
	'hr' => 'ftp.hr.debian.org',
	'hu' => 'ftp.hu.debian.org',
	'ie' => 'ftp.ie.debian.org',
	'is' => 'ftp.is.debian.org',
	'it' => 'ftp.it.debian.org',
	'jp' => 'ftp.jp.debian.org',
	'kr' => 'ftp.kr.debian.org',
	'mx' => 'ftp.mx.debian.org',
	'nl' => 'ftp.nl.debian.org',
	'no' => 'ftp.no.debian.org',
	'nz' => 'ftp.nz.debian.org',
	'pl' => 'ftp.pl.debian.org',
	'pt' => 'ftp.pt.debian.org',
	'ro' => 'ftp.ro.debian.org',
	'ru' => 'ftp.ru.debian.org',
	'se' => 'ftp.se.debian.org',
	'si' => 'ftp.si.debian.org',
	'sk' => 'ftp.sk.debian.org',
	'tr' => 'ftp.tr.debian.org',
	'tw' => 'ftp.tw.debian.org',
	'gb' => 'ftp.uk.debian.org',
	'us' => 'ftp.us.debian.org',
    };
}

my $keymaphash =  {
    'dk'     => ['Danish', 'da', 'qwerty/dk-latin1.kmap.gz', 'dk', 'nodeadkeys'],
    'de'     => ['German', 'de', 'qwertz/de-latin1-nodeadkeys.kmap.gz', 'de', 'nodeadkeys' ],
    'de-ch'  => ['Swiss-German', 'de-ch', 'qwertz/sg-latin1.kmap.gz',  'ch', 'de_nodeadkeys' ],
    'en-gb'  => ['United Kingdom', 'en-gb', 'qwerty/uk.kmap.gz' , 'gb', undef],
    'en-us'  => ['U.S. English', 'en-us', 'qwerty/us-latin1.kmap.gz',  'us', undef ],
    'es'     => ['Spanish', 'es', 'qwerty/es.kmap.gz', 'es', 'nodeadkeys'],
    #'et'     => [], # Ethopia or Estonia ??
    'fi'     => ['Finnish', 'fi', 'qwerty/fi-latin1.kmap.gz', 'fi', 'nodeadkeys'],
    #'fo'     => ['Faroe Islands', 'fo', ???, 'fo', 'nodeadkeys'],
    'fr'     => ['French', 'fr', 'azerty/fr-latin1.kmap.gz', 'fr', 'nodeadkeys'],
    'fr-be'  => ['Belgium-French', 'fr-be', 'azerty/be2-latin1.kmap.gz', 'be', 'nodeadkeys'],
    'fr-ca'  => ['Canada-French', 'fr-ca', 'qwerty/cf.kmap.gz', 'ca', 'fr-legacy'],
    'fr-ch'  => ['Swiss-French', 'fr-ch', 'qwertz/fr_CH-latin1.kmap.gz', 'ch', 'fr_nodeadkeys'],
    #'hr'     => ['Croatia', 'hr', 'qwertz/croat.kmap.gz', 'hr', ??], # latin2?
    'hu'     => ['Hungarian', 'hu', 'qwertz/hu.kmap.gz', 'hu', undef],
    'is'     => ['Icelandic', 'is', 'qwerty/is-latin1.kmap.gz', 'is', 'nodeadkeys'],
    'it'     => ['Italian', 'it', 'qwerty/it2.kmap.gz', 'it', 'nodeadkeys'],
    'jp'     => ['Japanese', 'ja', 'qwerty/jp106.kmap.gz', 'jp', undef],
    'lt'     => ['Lithuanian', 'lt', 'qwerty/lt.kmap.gz', 'lt', 'std'],
    #'lv'     => ['Latvian', 'lv', 'qwerty/lv-latin4.kmap.gz', 'lv', ??], # latin4 or latin7?
    'mk'     => ['Macedonian', 'mk', 'qwerty/mk.kmap.gz', 'mk', 'nodeadkeys'],
    'nl'     => ['Dutch', 'nl', 'qwerty/nl.kmap.gz', 'nl', undef],
    #'nl-be'  => ['Belgium-Dutch', 'nl-be', ?, ?, ?],
    'no'   => ['Norwegian', 'no', 'qwerty/no-latin1.kmap.gz', 'no', 'nodeadkeys'],
    'pl'     => ['Polish', 'pl', 'qwerty/pl.kmap.gz', 'pl', undef],
    'pt'     => ['Portuguese', 'pt', 'qwerty/pt-latin1.kmap.gz', 'pt', 'nodeadkeys'],
    'pt-br'  => ['Brazil-Portuguese', 'pt-br', 'qwerty/br-latin1.kmap.gz', 'br', 'nodeadkeys'],
    #'ru'     => ['Russian', 'ru', 'qwerty/ru.kmap.gz', 'ru', undef], # don't know?
    'si'     => ['Slovenian', 'sl', 'qwertz/slovene.kmap.gz', 'si', undef],
    'se'     => ['Swedish', 'sv', 'qwerty/se-latin1.kmap.gz', 'se', 'nodeadkeys'],
    #'th'     => [],
    'tr'     => ['Turkish', 'tr', 'qwerty/trq.kmap.gz', 'tr', undef],
};

my $kvmkeymaparray = [];
foreach my $lc (sort keys %$keymaphash) {
    push @$kvmkeymaparray, $keymaphash->{$lc}->[1];
}

sub kvmkeymaps {
    return $keymaphash;
}

sub kvmkeymaplist {
    return $kvmkeymaparray;
}

sub extract_param {
    my ($param, $key) = @_;

    my $res = $param->{$key};
    delete $param->{$key};

    return $res;
}

# For extracting sensitive keys (e.g. password), to avoid writing them to www-data owned configs
sub extract_sensitive_params :prototype($$$) {
    my ($param, $sensitive_list, $delete_list) = @_;

    my %delete = map { $_ => 1 } ($delete_list || [])->@*;

    my $sensitive = {};
    for my $opt (@$sensitive_list) {
	# handle deletions as explicitly setting `undef`, so subs which only have $param but not
	# $delete_list available can recognize them. Afterwards new values  may override.
	if (exists($delete{$opt})) {
	    $sensitive->{$opt} = undef;
	}

	if (defined(my $value = extract_param($param, $opt))) {
	    $sensitive->{$opt} = $value;
	}
    }

    return $sensitive;
}

# Note: we use this to wait until vncterm/spiceterm is ready
sub wait_for_vnc_port {
    my ($port, $family, $timeout) = @_;

    $timeout = 5 if !$timeout;
    my $sleeptime = 0;
    my $starttime = [gettimeofday];
    my $elapsed;

    my $cmd = ['/bin/ss', '-Htln', "sport = :$port"];
    push @$cmd, $family == AF_INET6 ? '-6' : '-4' if defined($family);

    my $found;
    while (($elapsed = tv_interval($starttime)) < $timeout) {
	# -Htln = don't print header, tcp, listening sockets only, numeric ports
	run_command($cmd, outfunc => sub {
	    my $line = shift;
	    if ($line =~ m/^LISTEN\s+\d+\s+\d+\s+\S+:(\d+)\s/) {
		$found = 1 if ($port == $1);
	    }
	});
	return 1 if $found;
	$sleeptime += 100000 if  $sleeptime < 1000000;
	usleep($sleeptime);
    }

    die "Timeout while waiting for port '$port' to get ready!\n";
}

sub next_unused_port {
    my ($range_start, $range_end, $family, $address) = @_;

    # We use a file to register allocated ports.
    # Those registrations expires after $expiretime.
    # We use this to avoid race conditions between
    # allocation and use of ports.

    my $filename = "/var/tmp/pve-reserved-ports";

    my $code = sub {

	my $expiretime = 5;
	my $ctime = time();

	my $ports = {};

	if (my $fh = IO::File->new ($filename, "r")) {
	    while (my $line = <$fh>) {
		if ($line =~ m/^(\d+)\s(\d+)$/) {
		    my ($port, $timestamp) = ($1, $2);
		    if (($timestamp + $expiretime) > $ctime) {
			$ports->{$port} = $timestamp; # not expired
		    }
		}
	    }
	}

	my $newport;
	my %sockargs = (Listen => 5,
			ReuseAddr => 1,
			Family    => $family,
			Proto     => IPPROTO_TCP,
			GetAddrInfoFlags => 0);
	$sockargs{LocalAddr} = $address if defined($address);

	for (my $p = $range_start; $p < $range_end; $p++) {
	    next if $ports->{$p}; # reserved

	    $sockargs{LocalPort} = $p;
	    my $sock = IO::Socket::IP->new(%sockargs);

	    if ($sock) {
		close($sock);
		$newport = $p;
		$ports->{$p} = $ctime;
		last;
	    }
	}

	my $data = "";
	foreach my $p (keys %$ports) {
	    $data .= "$p $ports->{$p}\n";
	}

	file_set_contents($filename, $data);

	return $newport;
    };

    my $p = lock_file('/var/lock/pve-ports.lck', 10, $code);
    die $@ if $@;

    die "unable to find free port (${range_start}-${range_end})\n" if !$p;

    return $p;
}

sub next_migrate_port {
    my ($family, $address) = @_;
    return next_unused_port(60000, 60050, $family, $address);
}

sub next_vnc_port {
    my ($family, $address) = @_;
    return next_unused_port(5900, 6000, $family, $address);
}

sub spice_port_range {
    return (61000, 61999);
}

sub next_spice_port {
    my ($family, $address) = @_;
    return next_unused_port(spice_port_range(), $family, $address);
}

sub must_stringify {
	my ($value) = @_;
	eval { $value = "$value" };
	return "error turning value into a string: $@" if $@;
	return $value;
}

# sigkill after $timeout  a $sub running in a fork if it can't write a pipe
# the $sub has to return a single scalar
sub run_fork_with_timeout {
    my ($timeout, $sub) = @_;

    my $res;
    my $error;
    my $pipe_out = IO::Pipe->new();

    # disable pending alarms, save their remaining time
    my $prev_alarm = alarm 0;

    # avoid leaving a zombie if the parent gets interrupted
    my $sig_received;

    my $child = fork();
    if (!defined($child)) {
	die "fork failed: $!\n";
	return $res;
    }

    if (!$child) {
	$pipe_out->writer();

	eval {
	    $res = $sub->();
	    print {$pipe_out} encode_json({ result => $res });
	    $pipe_out->flush();
	};
	if (my $err = $@) {
	    print {$pipe_out} encode_json({ error => must_stringify($err) });
	    $pipe_out->flush();
	    POSIX::_exit(1);
	}
	POSIX::_exit(0);
    }

    local $SIG{INT} = sub { $sig_received++; };
    local $SIG{TERM} = sub {
	$error //= "interrupted by unexpected signal\n";
	kill('TERM', $child);
    };

    $pipe_out->reader();

    my $readvalues = sub {
	local $/ = undef;
	my $child_res = decode_json(readline_nointr($pipe_out));
	$res = $child_res->{result};
	$error = $child_res->{error};
    };
    eval {
	if (defined($timeout)) {
	    run_with_timeout($timeout, $readvalues);
	} else {
	    $readvalues->();
	}
    };
    warn $@ if $@;
    $pipe_out->close();
    kill('KILL', $child);
    # FIXME: hangs if $child doesn't exits?! (D state)
    waitpid($child, 0);

    alarm $prev_alarm;
    die "interrupted by unexpected signal\n" if $sig_received;

    die $error if $error;
    return $res;
}

sub run_fork {
    my ($code) = @_;
    return run_fork_with_timeout(undef, $code);
}

# NOTE: NFS syscall can't be interrupted, so alarm does
# not work to provide timeouts.
# from 'man nfs': "Only SIGKILL can interrupt a pending NFS operation"
# So fork() before using Filesys::Df
sub df {
    my ($path, $timeout) = @_;

    my $df = sub { return Filesys::Df::df($path, 1) };

    my $res = eval { run_fork_with_timeout($timeout, $df) } // {};
    warn $@ if $@;

    # untaint, but be flexible: PB usage can result in scientific notation
    my ($blocks, $used, $bavail) = map { defined($_) ? (/^([\d\.e\-+]+)$/) : 0 }
	$res->@{qw(blocks used bavail)};

    return {
	total => $blocks,
	used => $used,
	avail => $bavail,
    };
}

sub du {
    my ($path, $timeout) = @_;

    my $size;

    $timeout //= 10;

    my $parser = sub {
	my $line = shift;

	if ($line =~ m/^(\d+)\s+total$/) {
	    $size = $1;
	}
    };

    run_command(['du', '-scb', $path], outfunc => $parser, timeout => $timeout);

    return $size;
}

# UPID helper
# We use this to uniquely identify a process.
# An 'Unique Process ID' has the following format:
# "UPID:$node:$pid:$pstart:$startime:$dtype:$id:$user"

sub upid_encode {
    my $d = shift;

    # Note: pstart can be > 32bit if uptime > 497 days, so this can result in
    # more that 8 characters for pstart
    return sprintf("UPID:%s:%08X:%08X:%08X:%s:%s:%s:", $d->{node}, $d->{pid},
		   $d->{pstart}, $d->{starttime}, $d->{type}, $d->{id},
		   $d->{user});
}

sub upid_decode {
    my ($upid, $noerr) = @_;

    my $res;
    my $filename;

    # "UPID:$node:$pid:$pstart:$startime:$dtype:$id:$user"
    # Note: allow up to 9 characters for pstart (work until 20 years uptime)
    if ($upid =~ m/^UPID:([a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?):([0-9A-Fa-f]{8}):([0-9A-Fa-f]{8,9}):([0-9A-Fa-f]{8}):([^:\s]+):([^:\s]*):([^:\s]+):$/) {
	$res->{node} = $1;
	$res->{pid} = hex($3);
	$res->{pstart} = hex($4);
	$res->{starttime} = hex($5);
	$res->{type} = $6;
	$res->{id} = $7;
	$res->{user} = $8;

	my $subdir = substr($5, 7, 8);
	$filename = "$pvetaskdir/$subdir/$upid";

    } else {
	return undef if $noerr;
	die "unable to parse worker upid '$upid'\n";
    }

    return wantarray ? ($res, $filename) : $res;
}

sub upid_open {
    my ($upid) = @_;

    my ($task, $filename) = upid_decode($upid);

    my $dirname = dirname($filename);
    make_path($dirname);

    my $wwwid = getpwnam('www-data') ||
	die "getpwnam failed";

    my $perm = 0640;

    my $outfh = IO::File->new ($filename, O_WRONLY|O_CREAT|O_EXCL, $perm) ||
	die "unable to create output file '$filename' - $!\n";
    chown $wwwid, -1, $outfh;

    return $outfh;
};

sub upid_read_status {
    my ($upid) = @_;

    my ($task, $filename) = upid_decode($upid);
    my $fh = IO::File->new($filename, "r");
    return "unable to open file - $!" if !$fh;
    my $maxlen = 4096;
    sysseek($fh, -$maxlen, 2);
    my $readbuf = '';
    my $br = sysread($fh, $readbuf, $maxlen);
    close($fh);
    if ($br) {
	return "unable to extract last line"
	    if $readbuf !~ m/\n?(.+)$/;
	my $line = $1;
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

# Check if the status returned by upid_read_status is an error status.
# If the status could not be parsed it's also treated as an error.
sub upid_status_is_error {
    my ($status) = @_;

    return !($status eq 'OK' || $status =~ m/^WARNINGS: \d+$/);
}

# takes the parsed status and returns the type, either ok, warning, error or unknown
sub upid_normalize_status_type {
    my ($status) = @_;

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

# useful functions to store comments in config files
sub encode_text {
    my ($text) = @_;

    # all control and hi-bit characters, and ':'
    my $unsafe = "^\x20-\x39\x3b-\x7e";
    return uri_escape(Encode::encode("utf8", $text), $unsafe);
}

sub decode_text {
    my ($data) = @_;

    return Encode::decode("utf8", uri_unescape($data));
}

# NOTE: deprecated - do not use! we now decode all parameters by default
sub decode_utf8_parameters {
    my ($param) = @_;

    foreach my $p (qw(comment description firstname lastname)) {
	$param->{$p} = decode('utf8', $param->{$p}) if $param->{$p};
    }

    return $param;
}

sub random_ether_addr {
    my ($prefix) = @_;

    my ($seconds, $microseconds) = gettimeofday;

    my $rand = Digest::SHA::sha1($$, rand(), $seconds, $microseconds);

    # clear multicast, set local id
    vec($rand, 0, 8) = (vec($rand, 0, 8) & 0xfe) | 2;

    my $addr = sprintf("%02X:%02X:%02X:%02X:%02X:%02X", unpack("C6", $rand));
    if (defined($prefix)) {
	$addr = uc($prefix) . substr($addr, length($prefix));
    }
    return $addr;
}

sub shellquote {
    my $str = shift;

    return String::ShellQuote::shell_quote($str);
}

sub cmd2string {
    my ($cmd) = @_;

    die "no arguments" if !$cmd;

    return $cmd if !ref($cmd);

    my @qa = ();
    foreach my $arg (@$cmd) { push @qa, shellquote($arg); }

    return join (' ', @qa);
}

# split an shell argument string into an array,
sub split_args {
    my ($str) = @_;

    return $str ? [ Text::ParseWords::shellwords($str) ] : [];
}

sub dump_logfile_by_filehandle {
    my ($fh, $filter, $state) = @_;

    my $count = ($state->{count} //= 0);
    my $lines = ($state->{lines} //= []);
    my $start = ($state->{start} //= 0);
    my $limit = ($state->{limit} //= 50);
    my $final = ($state->{final} //= 1);
    my $read_until_end = ($state->{read_until_end} //= $limit == 0);

    my $line;
    if ($filter) {
	# duplicate code, so that we do not slow down normal path
	while (defined($line = <$fh>)) {
	    if (ref($filter) eq 'CODE') {
		next if !$filter->($line);
	    } else {
		next if $line !~ m/$filter/;
	    }
	    next if $count++ < $start;
	    if (!$read_until_end) {
		next if $limit <= 0;
		$limit--;
	    }
	    chomp $line;
	    push @$lines, { n => $count, t => $line};
	}
    } else {
	while (defined($line = <$fh>)) {
	    next if $count++ < $start;
	    if (!$read_until_end) {
		next if $limit <= 0;
		$limit--;
	    }
	    chomp $line;
	    push @$lines, { n => $count, t => $line};
	}
    }

    # HACK: ExtJS store.guaranteeRange() does not like empty array
    # so we add a line
    if (!$count && $final) {
	$count++;
	push @$lines, { n => $count, t => "no content"};
    }

    $state->{count} = $count;
    $state->{limit} = $limit;
}

sub dump_logfile {
    my ($filename, $start, $limit, $filter) = @_;

    my $fh = IO::File->new($filename, "r");
    if (!$fh) {
	return (1, { n => 1, t => "unable to open file - $!"});
    }

    my %state = (
	'count' => 0,
	'lines' => [],
	'start' => $start,
	'limit' => $limit,
    );

    dump_logfile_by_filehandle($fh, $filter, \%state);

    close($fh);

    return ($state{'count'}, $state{'lines'});
}

sub dump_journal {
    my ($start, $limit, $since, $until, $service) = @_;

    my $lines = [];
    my $count = 0;

    $start = 0 if !$start;
    $limit = 50 if !$limit;

    my $parser = sub {
	my $line = shift;

        return if $count++ < $start;
	return if $limit <= 0;
	push @$lines, { n => int($count), t => $line};
	$limit--;
    };

    my $cmd = ['journalctl', '-o', 'short', '--no-pager'];

    push @$cmd, '--unit', $service if $service;
    push @$cmd, '--since', $since if $since;
    push @$cmd, '--until', $until if $until;
    run_command($cmd, outfunc => $parser);

    # HACK: ExtJS store.guaranteeRange() does not like empty array
    # so we add a line
    if (!$count) {
	$count++;
	push @$lines, { n => $count, t => "no content"};
    }

    return ($count, $lines);
}

sub dir_glob_regex {
    my ($dir, $regex) = @_;

    my $dh = IO::Dir->new ($dir);
    return wantarray ? () : undef if !$dh;

    while (defined(my $tmp = $dh->read)) {
	if (my @res = $tmp =~ m/^($regex)$/) {
	    $dh->close;
	    return wantarray ? @res : $tmp;
	}
    }
    $dh->close;

    return wantarray ? () : undef;
}

sub dir_glob_foreach {
    my ($dir, $regex, $func) = @_;

    my $dh = IO::Dir->new ($dir);
    if (defined $dh) {
	while (defined(my $tmp = $dh->read)) {
	    if (my @res = $tmp =~ m/^($regex)$/) {
		&$func (@res);
	    }
	}
    }
}

sub assert_if_modified {
    my ($digest1, $digest2) = @_;

    if ($digest1 && $digest2 && ($digest1 ne $digest2)) {
	die "detected modified configuration - file changed by other user? Try again.\n";
    }
}

# Digest for short strings
# like FNV32a, but we only return 31 bits (positive numbers)
sub fnv31a {
    my ($string) = @_;

    my $hval = 0x811c9dc5;

    foreach my $c (unpack('C*', $string)) {
	$hval ^= $c;
	$hval += (
	    (($hval << 1) ) +
	    (($hval << 4) ) +
	    (($hval << 7) ) +
	    (($hval << 8) ) +
	    (($hval << 24) ) );
	$hval = $hval & 0xffffffff;
    }
    return $hval & 0x7fffffff;
}

sub fnv31a_hex { return sprintf("%X", fnv31a(@_)); }

sub unpack_sockaddr_in46 {
    my ($sin) = @_;
    my $family = Socket::sockaddr_family($sin);
    my ($port, $host) = ($family == AF_INET6 ? Socket::unpack_sockaddr_in6($sin)
                                             : Socket::unpack_sockaddr_in($sin));
    return ($family, $port, $host);
}

sub getaddrinfo_all {
    my ($hostname, @opts) = @_;
    my %hints = (
	flags => AI_V4MAPPED | AI_ALL,
	@opts,
    );
    my ($err, @res) = Socket::getaddrinfo($hostname, '0', \%hints);
    die "failed to get address info for: $hostname: $err\n" if $err;
    return @res;
}

sub get_host_address_family {
    my ($hostname, $socktype) = @_;
    my @res = getaddrinfo_all($hostname, socktype => $socktype);
    return $res[0]->{family};
}

# get the fully qualified domain name of a host
# same logic as hostname(1): The FQDN is the name getaddrinfo(3) returns,
# given a nodename as a parameter
sub get_fqdn {
    my ($nodename) = @_;

    my $hints = {
	flags => AI_CANONNAME,
	socktype => SOCK_DGRAM
    };

    my ($err, @addrs) = Socket::getaddrinfo($nodename, undef, $hints);

    die "getaddrinfo: $err" if $err;

    return $addrs[0]->{canonname};
}

# Parses any sane kind of host, or host+port pair:
# The port is always optional and thus may be undef.
sub parse_host_and_port {
    my ($address) = @_;
    if ($address =~ /^($IPV4RE|[[:alnum:]\-.]+)(?::(\d+))?$/ ||             # ipv4 or host with optional ':port'
        $address =~ /^\[($IPV6RE|$IPV4RE|[[:alnum:]\-.]+)\](?::(\d+))?$/ || # anything in brackets with optional ':port'
        $address =~ /^($IPV6RE)(?:\.(\d+))?$/)                              # ipv6 with optional port separated by dot
    {
	return ($1, $2, 1); # end with 1 to support simple if(parse...) tests
    }
    return; # nothing
}

sub setresuid($$$) {
    my ($ruid, $euid, $suid) = @_;
    return 0 == syscall(PVE::Syscall::setresuid, int($ruid), int($euid), int($suid));
}

sub unshare($) {
    my ($flags) = @_;
    return 0 == syscall(PVE::Syscall::unshare, int($flags));
}

sub setns($$) {
    my ($fileno, $nstype) = @_;
    return 0 == syscall(PVE::Syscall::setns, int($fileno), int($nstype));
}

sub syncfs($) {
    my ($fileno) = @_;
    return 0 == syscall(PVE::Syscall::syncfs, int($fileno));
}

sub fsync($) {
    my ($fileno) = @_;
    return 0 == syscall(PVE::Syscall::fsync, int($fileno));
}

sub renameat2($$$$$) {
    my ($olddirfd, $oldpath, $newdirfd, $newpath, $flags) = @_;
    return 0 == syscall(
	PVE::Syscall::renameat2,
	int($olddirfd),
	$oldpath,
	int($newdirfd),
	$newpath,
	int($flags),
    );
}

sub sync_mountpoint {
    my ($path) = @_;
    sysopen my $fd, $path, O_RDONLY|O_CLOEXEC or die "failed to open $path: $!\n";
    my $syncfs_err;
    if (!syncfs(fileno($fd))) {
	$syncfs_err = "$!";
    }
    close($fd);
    die "syncfs '$path' failed - $syncfs_err\n" if defined $syncfs_err;
}

my sub check_mail_addr {
    my ($addr) = @_;
    die "'$addr' does not look like a valid email address or username\n"
	if $addr !~ /^$EMAIL_RE$/ && $addr !~ /^$EMAIL_USER_RE$/;
}

# support sending multi-part mail messages with a text and or a HTML part
# mailto may be a single email string or an array of receivers
sub sendmail {
    my ($mailto, $subject, $text, $html, $mailfrom, $author) = @_;

    $mailto = [ $mailto ] if !ref($mailto);

    check_mail_addr($_) for $mailto->@*;
    my $to_quoted = [ map { shellquote($_) } $mailto->@* ];

    $mailfrom = $mailfrom || "root";
    check_mail_addr($mailfrom);
    my $from_quoted = shellquote($mailfrom);

    $author = $author // 'Proxmox VE';

    open (my $mail, "|-", "sendmail", "-B", "8BITMIME", "-f", $from_quoted, "--", $to_quoted->@*)
	or die "unable to open 'sendmail' - $!";

    my $is_multipart = $text && $html;
    my $boundary = "----_=_NextPart_001_" . int(time()) . $$; # multipart spec, see rfc 1521

    $subject = Encode::encode('MIME-Header', $subject) if $subject =~ /[^[:ascii:]]/;

    print $mail "MIME-Version: 1.0\n" if $subject =~ /[^[:ascii:]]/ || $is_multipart;

    print $mail "From: $author <$mailfrom>\n";
    print $mail "To: " . join(', ', @$mailto) ."\n";
    print $mail "Date: " . time2str('%a, %d %b %Y %H:%M:%S %z', time()) . "\n";
    print $mail "Subject: $subject\n";

    if ($is_multipart) {
	print $mail "Content-Type: multipart/alternative;\n";
	print $mail "\tboundary=\"$boundary\"\n";
	print $mail "\n";
	print $mail "This is a multi-part message in MIME format.\n\n";
	print $mail "--$boundary\n";
    }

    if (defined($text)) {
	print $mail "Content-Type: text/plain;\n";
	print $mail "\tcharset=\"UTF-8\"\n";
	print $mail "Content-Transfer-Encoding: 8bit\n";
	print $mail "\n";

	# avoid 'remove extra line breaks' issue (MS Outlook)
	my $fill = '  ';
	$text =~ s/^/$fill/gm;

	print $mail $text;

	print $mail "\n--$boundary\n" if $is_multipart;
    }

    if (defined($html)) {
	print $mail "Content-Type: text/html;\n";
	print $mail "\tcharset=\"UTF-8\"\n";
	print $mail "Content-Transfer-Encoding: 8bit\n";
	print $mail "\n";

	print $mail $html;

	print $mail "\n--$boundary--\n" if $is_multipart;
    }

    close($mail);
}

# creates a temporary file that does not shows up on the file system hierarchy.
#
# Uses O_TMPFILE if available, which makes it just an anon inode that never shows up in the FS.
# If O_TMPFILE is not available, which unlikely nowadays (added in 3.11 kernel and all FS relevant
# for us support it) back to open-create + immediate unlink while still holding the file  handle.
#
# TODO: to avoid FS dependent features we could (transparently) switch to memfd_create as backend
sub tempfile {
    my ($perm, %opts) = @_;

    # default permissions are stricter than with file_set_contents
    $perm = 0600 if !defined($perm);

    my $dir = $opts{dir};
    if (!$dir) {
	if (-d "/run/user/$<") {
	    $dir = "/run/user/$<";
	} elsif ($< == 0) {
	    $dir = "/run";
	} else {
	    $dir = "/tmp";
	}
    }
    my $mode = $opts{mode} // O_RDWR;
    $mode |= O_EXCL if !$opts{allow_links};

    my $fh = IO::File->new($dir, $mode | O_TMPFILE, $perm);
    if (!$fh && $! == EOPNOTSUPP) {
	$dir = '/tmp' if !defined($opts{dir});
	$dir .= "/.tmpfile.$$";
	$fh = IO::File->new($dir, $mode | O_CREAT | O_EXCL, $perm);
	unlink($dir) if $fh;
    }
    die "failed to create tempfile: $!\n" if !$fh;
    return $fh;
}

# create an (ideally) anon file with the $data as content and return its FD-path and FH
sub tempfile_contents {
    my ($data, $perm, %opts) = @_;

    my $fh = tempfile($perm, %opts);
    eval {
	die "unable to write to tempfile: $!\n" if !print {$fh} $data;
	die "unable to flush to tempfile: $!\n" if !defined($fh->flush());
    };
    if (my $err = $@) {
	close $fh;
	die $err;
    }

    return ("/proc/$$/fd/".$fh->fileno, $fh);
}

sub validate_ssh_public_keys {
    my ($raw) = @_;
    my @lines = split(/\n/, $raw);

    foreach my $line (@lines) {
	next if $line =~ m/^\s*$/;
	eval {
	    my ($filename, $handle) = tempfile_contents($line);
	    run_command(["ssh-keygen", "-l", "-f", $filename],
			outfunc => sub {}, errfunc => sub {});
	};
	die "SSH public key validation error\n" if $@;
    }
}

sub openat($$$;$) {
    my ($dirfd, $pathname, $flags, $mode) = @_;
    $dirfd = int($dirfd);
    $flags = int($flags);
    $mode = int($mode // 0);

    my $fd = syscall(PVE::Syscall::openat, $dirfd, $pathname, $flags, $mode);
    return undef if $fd < 0;
    # sysopen() doesn't deal with numeric file descriptors apparently
    # so we need to convert to a mode string for IO::Handle->new_from_fd
    my $flagstr = ($flags & O_RDWR) ? 'rw' : ($flags & O_WRONLY) ? 'w' : 'r';
    my $handle = IO::Handle->new_from_fd($fd, $flagstr);
    return $handle if $handle;
    my $err = $!; # save error before closing the raw fd
    syscall(PVE::Syscall::close, $fd); # close
    $! = $err;
    return undef;
}

sub mkdirat($$$) {
    my ($dirfd, $name, $mode) = @_;
    return syscall(PVE::Syscall::mkdirat, int($dirfd), $name, int($mode)) == 0;
}

sub fchownat($$$$$) {
    my ($dirfd, $pathname, $owner, $group, $flags) = @_;
    return syscall(
	PVE::Syscall::fchownat,
	int($dirfd),
	$pathname,
	int($owner),
	int($group),
	int($flags),
    ) == 0;
}

my $salt_starter = time();

sub encrypt_pw {
    my ($pw) = @_;

    $salt_starter++;
    my $salt = substr(Digest::SHA::sha1_base64(time() + $salt_starter + $$), 0, 8);

    # crypt does not want '+' in salt (see 'man crypt')
    $salt =~ s/\+/X/g;

    return crypt(encode("utf8", $pw), "\$5\$$salt\$");
}

# intended usage: convert_size($val, "kb" => "gb")
# we round up to the next integer by default
# E.g. `convert_size(1023, "b" => "kb")` returns 1
# use $no_round_up to switch this off, above example would then return 0
# this is also true for converting down e.g. 0.0005 gb to mb returns 1
# (0 if $no_round_up is true)
# allowed formats for value:
# 1234
# 1234.
# 1234.1234
# .1234
sub convert_size {
    my ($value, $from, $to, $no_round_up) = @_;

    my $units = {
	b  => 0,
	kb => 1,
	mb => 2,
	gb => 3,
	tb => 4,
	pb => 5,
    };

    die "no value given"
	if !defined($value) || $value eq "";

    $from = lc($from // ''); $to = lc($to // '');
    die "unknown 'from' and/or 'to' units ($from => $to)"
	if !defined($units->{$from}) || !defined($units->{$to});

    die "value '$value' is not a valid, positive number"
	if $value !~ m/^(?:[0-9]+\.?[0-9]*|[0-9]*\.[0-9]+)$/;

    my $shift_amount = ($units->{$from} - $units->{$to}) * 10;

    $value *= 2**$shift_amount;
    $value++ if !$no_round_up && ($value - int($value)) > 0.0;

    return int($value);
}

# uninterruptible readline
# retries on EINTR
sub readline_nointr {
    my ($fh) = @_;
    my $line;
    while (1) {
	$line = <$fh>;
	last if defined($line) || ($! != EINTR);
    }
    return $line;
}

my $host_arch;
sub get_host_arch {
    $host_arch = (POSIX::uname())[4] if !$host_arch;
    return $host_arch;
}

# Devices are: [ (12 bits minor) (12 bits major) (8 bits minor) ]
sub dev_t_major($) {
    my ($dev_t) = @_;
    return (int($dev_t) & 0xfff00) >> 8;
}

sub dev_t_minor($) {
    my ($dev_t) = @_;
    $dev_t = int($dev_t);
    return (($dev_t >> 12) & 0xfff00) | ($dev_t & 0xff);
}

# Given an array of array refs [ \[a b c], \[a b b], \[e b a] ]
# Returns the intersection of elements as a single array [a b]
sub array_intersect {
    my ($arrays) = @_;

    if (!ref($arrays->[0])) {
	$arrays = [ grep { ref($_) eq 'ARRAY' } @_ ];
    }

    return [] if scalar(@$arrays) == 0;
    return $arrays->[0] if scalar(@$arrays) == 1;

    my $array_unique = sub {
	my %seen = ();
	return grep { ! $seen{ $_ }++ } @_;
    };

    # base idea is to get all unique members from the first array, then
    # check the common elements with the next (uniquely made) one, only keep
    # those. Repeat for every array and at the end we only have those left
    # which exist in all arrays
    my $return_arr = [ $array_unique->(@{$arrays->[0]}) ];
    for my $i (1 .. $#$arrays) {
	my %count = ();
	# $return_arr is already unique, explicit at before the loop, implicit below.
	foreach my $element (@$return_arr, $array_unique->(@{$arrays->[$i]})) {
	    $count{$element}++;
	}
	$return_arr = [];
	foreach my $element (keys %count) {
	    push @$return_arr, $element if $count{$element} > 1;
	}
	last if scalar(@$return_arr) == 0; # empty intersection, early exit
    }

    return $return_arr;
}

sub open_tree($$$) {
    my ($dfd, $pathname, $flags) = @_;
    return PVE::Syscall::file_handle_result(syscall(
	&PVE::Syscall::open_tree,
	int($dfd),
	$pathname,
	int($flags),
    ));
}

sub move_mount($$$$$) {
    my ($from_dirfd, $from_pathname, $to_dirfd, $to_pathname, $flags) = @_;
    return 0 == syscall(
	&PVE::Syscall::move_mount,
	int($from_dirfd),
	$from_pathname,
	int($to_dirfd),
	$to_pathname,
	int($flags),
    );
}

sub fsopen($$) {
    my ($fsname, $flags) = @_;
    return PVE::Syscall::file_handle_result(syscall(&PVE::Syscall::fsopen, $fsname, int($flags)));
}

sub fsmount($$$) {
    my ($fd, $flags, $mount_attrs) = @_;
    return PVE::Syscall::file_handle_result(syscall(
	&PVE::Syscall::fsmount,
	int($fd),
	int($flags),
	int($mount_attrs),
    ));
}

sub fspick($$$) {
    my ($dirfd, $pathname, $flags) = @_;
    return PVE::Syscall::file_handle_result(syscall(
	&PVE::Syscall::fspick,
	int($dirfd),
	$pathname,
	int($flags),
    ));
}

sub fsconfig($$$$$) {
    my ($fd, $command, $key, $value, $aux) = @_;
    return 0 == syscall(
	&PVE::Syscall::fsconfig,
	int($fd),
	int($command),
	$key,
	$value,
	int($aux),
    );
}

# "raw" mount, old api, not for generic use (as it does not invoke any helpers).
# use for lower level stuff such as bind/remount/... or simple tmpfs mounts
sub mount($$$$$) {
    my ($source, $target, $filesystemtype, $mountflags, $data) = @_;
    return 0 == syscall(
	&PVE::Syscall::mount,
	$source,
	$target,
	$filesystemtype,
	int($mountflags),
	$data,
    );
}

# size is optional and defaults to 256, note that xattr limits are FS specific and that xattrs can
# get arbitrary long. pass `0` for $size in array context to get the actual size of a value
sub getxattr($$;$) {
    my ($path_or_handle, $name, $size) = @_;
    $size //= 256;
    my $buf = pack("x${size}");

    my $xattr_size = -1; # the actual size of the xattr, can be zero
    if (defined(my $fd = fileno($path_or_handle))) {
	$xattr_size = syscall(&PVE::Syscall::fgetxattr, $fd, $name, $buf, int($size));
    } else {
	$xattr_size = syscall(&PVE::Syscall::getxattr, $path_or_handle, $name, $buf, int($size));
    }
    if ($xattr_size < 0) {
	return undef;
    }
    $buf = substr($buf, 0, $xattr_size);
    return wantarray ? ($buf, $xattr_size) : $buf;
}

# NOTE: can take either a path or an open file handle, i.e., its multiplexing setxattr and fsetxattr
sub setxattr($$$;$) {
    my ($path_or_handle, $name, $value, $flags) = @_;
    my $size = length($value); # NOTE: seems to get correct length also for wide-characters in text..

    if (defined(my $fd = fileno($path_or_handle))) {
	return 0 == syscall(
	    &PVE::Syscall::fsetxattr,
	    $fd,
	    $name,
	    $value,
	    int($size),
	    int($flags // 0),
	);
    } else {
	return 0 == syscall(
	    &PVE::Syscall::setxattr,
	    $path_or_handle,
	    $name,
	    $value,
	    int($size),
	    int($flags // 0),
	);
    }
}

sub safe_compare {
    my ($left, $right, $cmp) = @_;

    return 0 if !defined($left) && !defined($right);
    return -1 if !defined($left);
    return 1 if !defined($right);
    return $cmp->($left, $right);
}


# opts is a hash ref with the following known properties
#  allow_overwrite - if 1, overwriting existing files is allowed, use with care. Default to false
#  hash_required - if 1, at least one checksum has to be specified otherwise an error will be thrown
#  http_proxy
#  https_proxy
#  verify_certificates - if 0 (false) we tell wget to ignore untrusted TLS certs. Default to true
#  md5sum|sha(1|224|256|384|512)sum - the respective expected checksum string
sub download_file_from_url {
    my ($dest, $url, $opts) = @_;

    my ($checksum_algorithm, $checksum_expected);
    for ('sha512', 'sha384', 'sha256', 'sha224', 'sha1', 'md5') {
	if (defined($opts->{"${_}sum"})) {
	    $checksum_algorithm = $_;
	    $checksum_expected = $opts->{"${_}sum"};
	    last;
	}
    }
    die "checksum required but not specified\n" if ($opts->{hash_required} && !$checksum_algorithm);

    print "downloading $url to $dest\n";

    if (-f $dest) {
	if ($checksum_algorithm) {
	    print "calculating checksum of existing file...";
	    my $checksum_got = get_file_hash($checksum_algorithm, $dest);

	    if (lc($checksum_got) eq lc($checksum_expected)) {
		print "OK, got correct file already, no need to download\n";
		return;
	    } elsif ($opts->{allow_overwrite}) {
		print "checksum mismatch: got '$checksum_got' != expect '$checksum_expected', re-download\n";
	    } else {
		print "\n";  # the front end expects the error to reside at the last line without any noise
		die "checksum mismatch: got '$checksum_got' != expect '$checksum_expected', aborting\n";
	    }
	} elsif (!$opts->{allow_overwrite}) {
	    die "refusing to override existing file '$dest'\n";
	}
    }

    my $tmpdest = "$dest.tmp.$$";
    eval {
	local $SIG{INT} = sub {
	    unlink $tmpdest or warn "could not cleanup temporary file: $!";
	    die "got interrupted by signal\n";
	};

	{ # limit the scope of the ENV change
	    local %ENV;
	    if ($opts->{http_proxy}) {
		$ENV{http_proxy} = $opts->{http_proxy};
	    }
	    if ($opts->{https_proxy}) {
		$ENV{https_proxy} = $opts->{https_proxy};
	    }

	    my $cmd = ['wget', '--progress=dot:giga', '-O', $tmpdest, $url];

	    if (!($opts->{verify_certificates} // 1)) { # default to true
		push @$cmd, '--no-check-certificate';
	    }

	    run_command($cmd, errmsg => "download failed");
	}

	if ($checksum_algorithm) {
	    print "calculating checksum...";

	    my $checksum_got = get_file_hash($checksum_algorithm, $tmpdest);

	    if (lc($checksum_got) eq lc($checksum_expected)) {
		print "OK, checksum verified\n";
	    } else {
		print "\n";  # the front end expects the error to reside at the last line without any noise
		die "checksum mismatch: got '$checksum_got' != expect '$checksum_expected'\n";
	    }
	}

	rename($tmpdest, $dest) or die "unable to rename temporary file: $!\n";
    };
    if (my $err = $@) {
	unlink $tmpdest or warn "could not cleanup temporary file: $!";
	die $err;
    }

    print "download of '$url' to '$dest' finished\n";
}

sub get_file_hash {
    my ($algorithm, $filename) = @_;

    my $algorithm_map = {
	'md5' => sub { Digest::MD5->new },
	'sha1' => sub { Digest::SHA->new(1) },
	'sha224' => sub { Digest::SHA->new(224) },
	'sha256' => sub { Digest::SHA->new(256) },
	'sha384' => sub { Digest::SHA->new(384) },
	'sha512' => sub { Digest::SHA->new(512) },
    };

    my $digester = $algorithm_map->{$algorithm}->() or die "unknown algorithm '$algorithm'\n";

    open(my $fh, '<', $filename) or die "unable to open '$filename': $!\n";
    binmode($fh);

    my $digest = $digester->addfile($fh)->hexdigest;

    return lc($digest);
}

1;
