package PVE::Tools;

use strict;
use warnings;
use POSIX qw(EINTR);
use IO::Socket::INET;
use IO::Select;
use File::Basename;
use File::Path qw(make_path);
use IO::File;
use IO::Dir;
use IPC::Open3;
use Fcntl qw(:DEFAULT :flock);
use base 'Exporter';
use URI::Escape;
use Encode;
use Digest::SHA;
use Text::ParseWords;
use String::ShellQuote;
use Time::HiRes qw(usleep gettimeofday tv_interval);

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
);

my $pvelogdir = "/var/log/pve";
my $pvetaskdir = "$pvelogdir/tasks";

mkdir $pvelogdir;
mkdir $pvetaskdir;

my $IPV4OCTET = "(?:25[0-5]|(?:[1-9]|1[0-9]|2[0-4])?[0-9])";
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

sub run_with_timeout {
    my ($timeout, $code, @param) = @_;

    die "got timeout\n" if $timeout <= 0;

    my $prev_alarm;

    my $sigcount = 0;

    my $res;

    local $SIG{ALRM} = sub { $sigcount++; }; # catch alarm outside eval

    eval {
	local $SIG{ALRM} = sub { $sigcount++; die "got timeout\n"; };
	local $SIG{PIPE} = sub { $sigcount++; die "broken pipe\n" };
	local $SIG{__DIE__};   # see SA bug 4631

	$prev_alarm = alarm($timeout);

	$res = &$code(@param);

	alarm(0); # avoid race conditions
    };

    my $err = $@;

    alarm($prev_alarm) if defined($prev_alarm);

    die "unknown error" if $sigcount && !$err; # seems to happen sometimes

    die $err if $err;

    return $res;
}

# flock: we use one file handle per process, so lock file
# can be called multiple times and succeeds for the same process.

my $lock_handles =  {};

sub lock_file_full {
    my ($filename, $timeout, $shared, $code, @param) = @_;

    $timeout = 10 if !$timeout;

    my $mode = $shared ? LOCK_SH : LOCK_EX;

    my $lock_func = sub {
        if (!$lock_handles->{$$}->{$filename}) {
            $lock_handles->{$$}->{$filename} = new IO::File (">>$filename") ||
                die "can't open file - $!\n";
        }

        if (!flock ($lock_handles->{$$}->{$filename}, $mode|LOCK_NB)) {
            print STDERR "trying to aquire lock...";
	    my $success;
	    while(1) {
		$success = flock($lock_handles->{$$}->{$filename}, $mode);
		# try again on EINTR (see bug #273)
		if ($success || ($! != EINTR)) {
		    last;
		}
	    }
            if (!$success) {
                print STDERR " failed\n";
                die "can't aquire lock - $!\n";
            }
            print STDERR " OK\n";
        }
    };

    my $res;

    eval { run_with_timeout($timeout, $lock_func); };
    my $err = $@;
    if ($err) {
	$err = "can't lock file '$filename' - $err";
    } else {
	eval { $res = &$code(@param) };
	$err = $@;
    }

    if (my $fh = $lock_handles->{$$}->{$filename}) {
        $lock_handles->{$$}->{$filename} = undef;
        close ($fh);
    }

    if ($err) {
        $@ = $err;
        return undef;
    }

    $@ = undef;

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
	my $fh = IO::File->new($tmpname, O_WRONLY|O_CREAT, $perm);
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

    my $content = safe_read_from($fh, $max);

    close $fh;

    return $content;
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
    my ($fh, $max, $oneline) = @_;

    $max = 32768 if !$max;

    my $br = 0;
    my $input = '';
    my $count;
    while ($count = sysread($fh, $input, 8192, $br)) {
	$br += $count;
	die "input too long - aborting\n" if $br > $max;
	if ($oneline && $input =~ m/^(.*)\n/) {
	    $input = $1;
	    last;
	}
    } 
    die "unable to read input - $!\n" if !defined($count);

    return $input;
}

sub run_command {
    my ($cmd, %param) = @_;

    my $old_umask;
    my $cmdstr;

    if (!ref($cmd)) {
	$cmdstr = $cmd;
	if ($cmd =~ m/|/) {
	    # see 'man bash' for option pipefail
	    $cmd = [ '/bin/bash', '-c', "set -o pipefail && $cmd" ];
	} else {
	    $cmd = [ $cmd ];
	}
    } else {
	$cmdstr = cmd2string($cmd);
    }

    my $errmsg;
    my $laststderr;
    my $timeout;
    my $oldtimeout;
    my $pid;

    my $outfunc;
    my $errfunc;
    my $logfunc;
    my $input;
    my $output;
    my $afterfork;

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

	# try to avoid locale related issues/warnings
	my $lang = $param{lang} || 'C'; 
 
	my $orig_pid = $$;

	eval {
	    local $ENV{LC_ALL} = $lang;

	    # suppress LVM warnings like: "File descriptor 3 left open";
	    local $ENV{LVM_SUPPRESS_FD_WARNINGS} = "1";

	    $pid = open3($writer, $reader, $error, @$cmd) || die $!;

	    # if we pipe fron STDIN, open3 closes STDIN, so we we
	    # a perl warning "Filehandle STDIN reopened as GENXYZ .. "
	    # as soon as we open a new file.
	    # to avoid that we open /dev/null
	    if (!ref($writer) && !defined(fileno(STDIN))) {
		POSIX::close(0);
		open(STDIN, "</dev/null");
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

	my $select = new IO::Select;
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
			    $outlog .= $buf;
			    while ($outlog =~ s/^([^\010\r\n]*)(\r|\n|(\010)+|\r\n)//s) {
				my $line = $1;
				&$outfunc($line) if $outfunc;
				&$logfunc($line) if $logfunc;
			    }
			};
			my $err = $@;
			if ($err) {
			    kill (9, $pid);
			    waitpid ($pid, 0);
			    die $err;
			}
		    } else {
			print $buf;
			*STDOUT->flush();
		    }
		} elsif ($h eq $error) {
		    if ($errfunc || $logfunc) {
			eval {
			    $errlog .= $buf;
			    while ($errlog =~ s/^([^\010\r\n]*)(\r|\n|(\010)+|\r\n)//s) {
				my $line = $1;
				&$errfunc($line) if $errfunc;
				&$logfunc($line) if $logfunc;
			    }
			};
			my $err = $@;
			if ($err) {
			    kill (9, $pid);
			    waitpid ($pid, 0);
			    die $err;
			}
		    } else {
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
	} elsif (my $ec = ($? >> 8)) {
	    if (!($ec == 24 && ($cmdstr =~ m|^(\S+/)?rsync\s|))) {
		if ($errmsg && $laststderr) {
		    my $lerr = $laststderr;
		    $laststderr = undef;
		    die "$lerr\n";
		}
		die "exit code $ec\n";
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
	} else {
	    die "command '$cmdstr' failed: $err";
	}
    }

    return undef;
}

sub split_list {
    my $listtxt = shift || '';

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
    while ($tmpl =~ m/([^{]+)?({([^}]+)})?/g) {
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
    #'ru'     => ['Russian', 'ru', 'qwerty/ru.kmap.gz', 'ru', undef], # dont know?
    'si'     => ['Slovenian', 'sl', 'qwertz/slovene.kmap.gz', 'si', undef],
    'se'     => ['Swedish', 'sv', 'qwerty/se-latin1.kmap.gz', 'se', 'nodeadkeys'],
    #'th'     => [],
    'tr'     => ['Turkish', 'tr', 'qwerty/trq.kmap.gz', 'tr', undef],
};

my $kvmkeymaparray = [];
foreach my $lc (keys %$keymaphash) {
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

# Note: we use this to wait until vncterm/spiceterm is ready
sub wait_for_vnc_port {
    my ($port, $timeout) = @_;

    $timeout = 5 if !$timeout;
    my $sleeptime = 0;
    my $starttime = [gettimeofday];
    my $elapsed;

    while (($elapsed = tv_interval($starttime)) < $timeout) {
	if (my $fh = IO::File->new ("/proc/net/tcp", "r")) {
	    while (defined (my $line = <$fh>)) {
		if ($line =~ m/^\s*\d+:\s+([0-9A-Fa-f]{8}):([0-9A-Fa-f]{4})\s/) {
		    if ($port == hex($2)) {
			close($fh);
			return 1;
		    }
		}
	    }
	    close($fh);
	}
	$sleeptime += 100000 if  $sleeptime < 1000000;
	usleep($sleeptime);
    }

    return undef;
}

sub next_unused_port {
    my ($range_start, $range_end) = @_;

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

	for (my $p = $range_start; $p < $range_end; $p++) {
	    next if $ports->{$p}; # reserved

	    my $sock = IO::Socket::INET->new(Listen => 5,
					     LocalAddr => 'localhost',
					     LocalPort => $p,
					     ReuseAddr => 1,
					     Proto     => 0);

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

    my $p = lock_file($filename, 10, $code);
    die $@ if $@;
   
    die "unable to find free port (${range_start}-${range_end})\n" if !$p;

    return $p;
}

sub next_migrate_port {
    return next_unused_port(60000, 60010);
}

sub next_vnc_port {
    return next_unused_port(5900, 6000);
}

sub next_spice_port {
    return next_unused_port(61000, 61099);
}

# NOTE: NFS syscall can't be interrupted, so alarm does 
# not work to provide timeouts.
# from 'man nfs': "Only SIGKILL can interrupt a pending NFS operation"
# So the spawn external 'df' process instead of using
# Filesys::Df (which uses statfs syscall)
sub df {
    my ($path, $timeout) = @_;

    my $cmd = [ 'df', '-P', '-B', '1', $path];

    my $res = {
	total => 0,
	used => 0,
	avail => 0,
    };

    my $parser = sub {
	my $line = shift;
	if (my ($fsid, $total, $used, $avail) = $line =~
	    m/^(\S+.*)\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s.*$/) {
	    $res = {
		total => $total,
		used => $used,
		avail => $avail,
	    };
	}
    };
    eval { run_command($cmd, timeout => $timeout, outfunc => $parser); };
    warn $@ if $@;

    return $res;
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
	} else {
	    return "unexpected status";
	}
    }
    return "unable to read tail (got $br bytes)";
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

sub decode_utf8_parameters {
    my ($param) = @_;

    foreach my $p (qw(comment description firstname lastname)) {
	$param->{$p} = decode('utf8', $param->{$p}) if $param->{$p};
    }

    return $param;
}

sub random_ether_addr {

    my ($seconds, $microseconds) = gettimeofday;

    my $rand = Digest::SHA::sha1_hex($$, rand(), $seconds, $microseconds);

    my $mac = '';
    for (my $i = 0; $i < 6; $i++) {
	my $ss = hex(substr($rand, $i*2, 2));
	if (!$i) {
	    $ss &= 0xfe; # clear multicast
	    $ss |= 2; # set local id
	}
	$ss = sprintf("%02X", $ss);

	if (!$i) {
	    $mac .= "$ss";
	} else {
	    $mac .= ":$ss";
	}
    }

    return $mac;
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

sub dump_logfile {
    my ($filename, $start, $limit, $filter) = @_;

    my $lines = [];
    my $count = 0;

    my $fh = IO::File->new($filename, "r");
    if (!$fh) { 
	$count++;
	push @$lines, { n => $count, t => "unable to open file - $!"};
	return ($count, $lines);
    }

    $start = 0 if !$start;
    $limit = 50 if !$limit;

    my $line;

    if ($filter) {
	# duplicate code, so that we do not slow down normal path
	while (defined($line = <$fh>)) {
	    next if $line !~ m/$filter/;
	    next if $count++ < $start;
	    next if $limit <= 0;
	    chomp $line;
	    push @$lines, { n => $count, t => $line};
	    $limit--;
	}
    } else {
	while (defined($line = <$fh>)) {
	    next if $count++ < $start;
	    next if $limit <= 0;
	    chomp $line;
	    push @$lines, { n => $count, t => $line};
	    $limit--;
	}
    }

    close($fh);

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

1;
