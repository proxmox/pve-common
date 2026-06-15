package PVE::Cmd;

use v5.36;

use IO::File;
use IO::Handle;
use IO::Select;
use IO::Socket::IP;
use IPC::Open3;
use POSIX qw();
use Socket qw(IPPROTO_TCP);
use String::ShellQuote ();
use Text::ParseWords;
use Time::HiRes qw(usleep alarm);

use base 'Exporter';

our @EXPORT_OK = qw(
    pipe_socket
    run
    run_command
    shell_quote
    split_args
    to_string
);

sub shell_quote($str) {
    return String::ShellQuote::shell_quote($str);
}

sub to_string($cmd) {
    die "no arguments" if !$cmd;

    return $cmd if !ref($cmd);

    my @qa = map { shell_quote($_) } $cmd->@*;

    return join(' ', @qa);
}

# split an shell argument string into an array,
sub split_args($str) {
    return $str ? [Text::ParseWords::shellwords($str)] : [];
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
sub run($cmd, %param) {
    my $old_umask;
    my $cmdstr;

    if (my $ref = ref($cmd)) {
        if (ref($cmd->[0])) {
            $cmdstr = 'set -o pipefail && ';
            my $pipe = '';
            foreach my $command (@$cmd) {
                # concatenate quoted parameters
                # strings which are passed by reference are NOT shell quoted
                $cmdstr .= $pipe . join(' ', map { ref($_) ? $$_ : shell_quote($_) } @$command);
                $pipe = ' | ';
            }
            $cmd = ['/bin/bash', '-c', "$cmdstr"];
        } else {
            $cmdstr = to_string($cmd);
        }
    } else {
        $cmdstr = $cmd;
        if ($cmd =~ m/\|/) {
            # see 'man bash' for option pipefail
            $cmd = ['/bin/bash', '-c', "set -o pipefail && $cmd"];
        } else {
            $cmd = [$cmd];
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
        my $error = IO::File->new();

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
            POSIX::_exit(1);
            kill('KILL', $$);
        }

        die $err if $err;

        local $SIG{ALRM} = sub { die "got timeout\n"; }
            if $timeout;
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
                my $count = sysread($h, $buf, 4096);
                if (!defined($count)) {
                    my $err = $!;
                    kill(9, $pid);
                    waitpid($pid, 0);
                    die $err;
                }
                $select->remove($h) if !$count;
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
                            kill(9, $pid);
                            waitpid($pid, 0);
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
                            kill(9, $pid);
                            waitpid($pid, 0);
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

        waitpid($pid, 0);

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

    umask($old_umask) if defined($old_umask);

    alarm($oldtimeout) if $oldtimeout;

    if ($err) {
        if ($pid && ($err eq "got timeout\n")) {
            kill(9, $pid);
            waitpid($pid, 0);
            die "command '$cmdstr' failed: $err";
        }

        if ($errmsg) {
            $err =~ s/^usermod:\s*// if $cmdstr =~ m|^(\S+/)?usermod\s|;
            die "$errmsg: $err";
        } elsif (!$noerr) {
            die "command '$cmdstr' failed: $err";
        }
    }

    return $exitcode;
}

# run() is the canonical name; run_command is kept as a migration wrapper
sub run_command {
    return run(@_);
}

# Run a command with a tcp socket as standard input.
sub pipe_socket($cmd, $ip, $port) {
    my $params = {
        Listen => 1,
        ReuseAddr => 1,
        Proto => Socket::IPPROTO_TCP(),
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
    # can't really use run().
    my $pid = fork() // die "fork failed: $!\n";
    if (!$pid) {
        POSIX::dup2(fileno($client), 0);
        POSIX::dup2(fileno($client), 1);
        close($client);
        exec { $cmd->[0] } @$cmd or do {
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

1;
