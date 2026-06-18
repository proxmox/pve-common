package PVE::INotify;

# todo: maybe we do not need update_file() ?
use strict;
use warnings;

use Clone qw(clone);
use Digest::SHA;
use Encode qw(encode decode);
use Fcntl qw(:DEFAULT :flock);
use File::Basename;
use File::stat;
use IO::Dir;
use IO::File;
use JSON;
use Linux::Inotify2;
use POSIX;

use PVE::Cmd;
use PVE::Exception qw(raise_param_exc);
use PVE::File;
use PVE::IPRoute2;
use PVE::JSONSchema;
use PVE::Network::Interfaces;
use PVE::ProcFSTools;
use PVE::SafeSyslog;
use PVE::Tools;
use PVE::UPID;

use base 'Exporter';

our @EXPORT_OK = qw(read_file write_file register_file nodename);

# moved to PVE::Network::Interfaces; aliased here for backwards compatibility
our $PHYSICAL_NIC_RE;
*PHYSICAL_NIC_RE = \$PVE::Network::Interfaces::PHYSICAL_NIC_RE;

my $ccache;
my $ccachemap;
my $ccacheregex;
my $inotify;
my $inotify_pid = 0;
my $versions;
my $shadowfiles = {
    '/etc/network/interfaces' => '/etc/network/interfaces.new',
};

# to enable cached operation, you need to call 'inotify_init'
# inotify handles are a limited resource, so use with care (only
# enable the cache if you really need it)

# Note: please close the inotify handle after you fork

sub ccache_default_writer {
    my ($filename, $data) = @_;

    die "undefined config writer for '$filename' :ERROR";
}

sub ccache_default_parser {
    my ($filename, $srcfd) = @_;

    die "undefined config reader for '$filename' :ERROR";
}

sub ccache_compute_diff {
    my ($filename, $shadow) = @_;

    my $diff = '';

    my $cmd = ['/usr/bin/diff', '-b', '-N', '-u', $filename, $shadow];
    PVE::Cmd::run(
        $cmd,
        noerr => 1,
        outfunc => sub {
            my ($line) = @_;
            $diff .= decode('UTF-8', $line) . "\n";
        },
    );

    $diff = undef if !$diff;

    return $diff;
}

sub ccache_info {
    my ($filename) = @_;

    foreach my $uid (keys %$ccacheregex) {
        my $ccinfo = $ccacheregex->{$uid};
        my $dir = $ccinfo->{dir};
        my $regex = $ccinfo->{regex};
        if ($filename =~ m|^$dir/+$regex$|) {
            if (!$ccache->{$filename}) {
                my $cp = {};
                while (my ($k, $v) = each %$ccinfo) {
                    $cp->{$k} = $v;
                }
                $ccache->{$filename} = $cp;
            }
            return ($ccache->{$filename}, $filename);
        }
    }

    $filename = $ccachemap->{$filename} if defined($ccachemap->{$filename});

    die "file '$filename' not added :ERROR" if !defined($ccache->{$filename});

    return ($ccache->{$filename}, $filename);
}

sub write_file {
    my ($fileid, $data, $full) = @_;

    my ($ccinfo, $filename) = ccache_info($fileid);

    my $writer = $ccinfo->{writer};

    my $realname = $filename;

    my $shadow;
    if ($shadow = $shadowfiles->{$filename}) {
        $realname = $shadow;
    }

    my $perm = $ccinfo->{perm} || 0644;

    my $tmpname = "$realname.tmp.$$";

    my $res;
    eval {
        my $fh = IO::File->new($tmpname, O_WRONLY | O_CREAT, $perm);
        die "unable to open file '$tmpname' - $!\n" if !$fh;

        $res = &$writer($filename, $fh, $data);

        die "closing file '$tmpname' failed - $!\n" unless close $fh;
    };
    my $err = $@;

    $ccinfo->{version} = undef;

    if ($err) {
        unlink $tmpname;
        die $err;
    }

    if (!rename($tmpname, $realname)) {
        my $msg = "close (rename) atomic file '$filename' failed: $!\n";
        unlink $tmpname;
        die $msg;
    }

    my $diff;
    if ($shadow && $full) {
        $diff = ccache_compute_diff($filename, $shadow);
    }

    if ($full) {
        return { data => $res, changes => $diff };
    }

    return $res;
}

sub update_file {
    my ($fileid, $data, @args) = @_;

    my ($ccinfo, $filename) = ccache_info($fileid);

    my $update = $ccinfo->{update};

    die "unable to update/merge data" if !$update;

    my $lkfn = "$filename.lock";

    my $timeout = 10;

    my $fd;

    my $code = sub {

        $fd = IO::File->new($filename, "r");

        my $new = &$update($filename, $fd, $data, @args);

        if (defined($new)) {
            PVE::File::file_set_contents($filename, $new, $ccinfo->{perm});
        } else {
            unlink $filename;
        }
    };

    PVE::Tools::lock_file($lkfn, $timeout, $code);
    my $err = $@;

    close($fd) if defined($fd);

    die $err if $err;

    return undef;
}

sub discard_changes {
    my ($fileid, $full) = @_;

    my ($ccinfo, $filename) = ccache_info($fileid);

    if (my $copy = $shadowfiles->{$filename}) {
        unlink $copy;
    }

    return read_file($filename, $full);
}

sub poll_changes {
    my ($filename) = @_;

    poll() if $inotify; # read new inotify events

    $versions->{$filename} = 0 if !defined($versions->{$filename});

    return $versions->{$filename};
}

sub read_file {
    my ($fileid, $full) = @_;

    my $parser;

    my ($ccinfo, $filename) = ccache_info($fileid);

    $parser = $ccinfo->{parser};

    my $fd;
    my $shadow;

    my $cver = poll_changes($filename);

    if (my $copy = $shadowfiles->{$filename}) {
        if ($fd = IO::File->new($copy, "r")) {
            $shadow = $copy;
        } else {
            $fd = IO::File->new($filename, "r");
        }
    } else {
        $fd = IO::File->new($filename, "r");
    }

    my $acp = $ccinfo->{always_call_parser};

    if (!$fd) {
        $ccinfo->{version} = undef;
        $ccinfo->{data} = undef;
        $ccinfo->{diff} = undef;
        return undef if !$acp;
    }

    my $noclone = $ccinfo->{noclone};

    # file unchanged?
    if (
        !$ccinfo->{nocache}
        && $inotify
        && $cver
        && defined($ccinfo->{data})
        && defined($ccinfo->{version})
        && ($ccinfo->{readonce}
            || ($ccinfo->{version} == $cver))
    ) {

        my $ret;
        if (!$noclone && ref($ccinfo->{data})) {
            $ret->{data} = clone($ccinfo->{data});
        } else {
            $ret->{data} = $ccinfo->{data};
        }
        $ret->{changes} = $ccinfo->{diff};

        return $full ? $ret : $ret->{data};
    }

    my $diff;

    if ($shadow) {
        $diff = ccache_compute_diff($filename, $shadow);
    }

    my $res = &$parser($filename, $fd);

    if (!$ccinfo->{nocache}) {
        $ccinfo->{version} = $cver;
    }

    # we cache data with references, so we always need to
    # clone this data. Else the original data may get
    # modified.
    $ccinfo->{data} = $res;

    # also store diff
    $ccinfo->{diff} = $diff;

    my $ret;
    if (!$noclone && ref($ccinfo->{data})) {
        $ret->{data} = clone($ccinfo->{data});
    } else {
        $ret->{data} = $ccinfo->{data};
    }
    $ret->{changes} = $ccinfo->{diff};

    return $full ? $ret : $ret->{data};
}

sub parse_ccache_options {
    my ($ccinfo, %options) = @_;

    foreach my $opt (keys %options) {
        my $v = $options{$opt};
        if ($opt eq 'readonce') {
            $ccinfo->{$opt} = $v;
        } elsif ($opt eq 'nocache') {
            $ccinfo->{$opt} = $v;
        } elsif ($opt eq 'shadow') {
            $ccinfo->{$opt} = $v;
        } elsif ($opt eq 'perm') {
            $ccinfo->{$opt} = $v;
        } elsif ($opt eq 'noclone') {
            # noclone flag for large read-only data chunks like aplinfo
            $ccinfo->{$opt} = $v;
        } elsif ($opt eq 'always_call_parser') {
            # when set, we call parser even when the file does not exist.
            # this allows the parser to return some default
            $ccinfo->{$opt} = $v;
        } else {
            die "internal error - unsupported option '$opt'";
        }
    }
}

sub register_file {
    my ($id, $filename, $parser, $writer, $update, %options) = @_;

    die "can't register file '$filename' after inotify_init" if $inotify;

    die "file '$filename' already added :ERROR" if defined($ccache->{$filename});
    die "ID '$id' already used :ERROR" if defined($ccachemap->{$id});

    my $ccinfo = {};

    $ccinfo->{id} = $id;
    $ccinfo->{parser} = $parser || \&ccache_default_parser;
    $ccinfo->{writer} = $writer || \&ccache_default_writer;
    $ccinfo->{update} = $update;

    parse_ccache_options($ccinfo, %options);

    if ($options{shadow}) {
        $shadowfiles->{$filename} = $options{shadow};
    }

    $ccachemap->{$id} = $filename;
    $ccache->{$filename} = $ccinfo;
}

sub register_regex {
    my ($dir, $regex, $parser, $writer, $update, %options) = @_;

    die "can't register regex after inotify_init" if $inotify;

    my $uid = "$dir/$regex";
    die "regular expression '$uid' already added :ERROR" if defined($ccacheregex->{$uid});

    my $ccinfo = {};

    $ccinfo->{dir} = $dir;
    $ccinfo->{regex} = $regex;
    $ccinfo->{parser} = $parser || \&ccache_default_parser;
    $ccinfo->{writer} = $writer || \&ccache_default_writer;
    $ccinfo->{update} = $update;

    parse_ccache_options($ccinfo, %options);

    $ccacheregex->{$uid} = $ccinfo;
}

sub poll {
    return if !$inotify;

    if ($inotify_pid != $$) {
        syslog('err', "got inotify poll request in wrong process - disabling inotify");
        $inotify = undef;
    } else {
        1 while $inotify && $inotify->poll;
    }
}

sub flushcache {
    foreach my $filename (keys %$ccache) {
        $ccache->{$filename}->{version} = undef;
        $ccache->{$filename}->{data} = undef;
        $ccache->{$filename}->{diff} = undef;
    }
}

sub inotify_close {
    $inotify = undef;
}

sub inotify_init {

    die "only one inotify instance allowed" if $inotify;

    $inotify = Linux::Inotify2->new()
        || die "Unable to create new inotify object: $!";

    $inotify->blocking(0);

    $versions = {};

    my $dirhash = {};
    foreach my $fn (keys %$ccache) {
        my $dir = dirname($fn);
        my $base = basename($fn);

        $dirhash->{$dir}->{$base} = $fn;

        if (my $sf = $shadowfiles->{$fn}) {
            $base = basename($sf);
            $dir = dirname($sf);
            $dirhash->{$dir}->{$base} = $fn; # change version of original file!
        }
    }

    foreach my $uid (keys %$ccacheregex) {
        my $ccinfo = $ccacheregex->{$uid};
        $dirhash->{ $ccinfo->{dir} }->{_regex} = 1;
    }

    $inotify_pid = $$;

    foreach my $dir (keys %$dirhash) {

        my $evlist = IN_MODIFY | IN_ATTRIB | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE | IN_CREATE;
        $inotify->watch(
            $dir,
            $evlist,
            sub {
                my $e = shift;
                my $name = $e->name;

                if ($inotify_pid != $$) {
                    syslog('err', "got inotify event in wrong process");
                }

                if ($e->IN_ISDIR || !$name) {
                    return;
                }

                if ($e->IN_Q_OVERFLOW) {
                    syslog('info', "got inotify overflow - flushing cache");
                    flushcache();
                    return;
                }

                if ($e->IN_UNMOUNT) {
                    syslog('err', "got 'unmount' event on '$name' - disabling inotify");
                    $inotify = undef;
                }
                if ($e->IN_IGNORED) {
                    syslog('err', "got 'ignored' event on '$name' - disabling inotify");
                    $inotify = undef;
                }

                if ($dirhash->{$dir}->{_regex}) {
                    foreach my $uid (keys %$ccacheregex) {
                        my $ccinfo = $ccacheregex->{$uid};
                        next if $dir ne $ccinfo->{dir};
                        my $regex = $ccinfo->{regex};
                        if ($regex && ($name =~ m|^$regex$|)) {

                            my $fn = "$dir/$name";
                            $versions->{$fn}++;
                            #print "VERSION:$fn:$versions->{$fn}\n";
                        }
                    }
                } elsif (my $fn = $dirhash->{$dir}->{$name}) {

                    $versions->{$fn}++;
                    #print "VERSION:$fn:$versions->{$fn}\n";
                }
            },
        );
    }

    foreach my $dir (keys %$dirhash) {
        foreach my $name (keys %{ $dirhash->{$dir} }) {
            if ($name eq '_regex') {
                foreach my $uid (keys %$ccacheregex) {
                    my $ccinfo = $ccacheregex->{$uid};
                    next if $dir ne $ccinfo->{dir};
                    my $re = $ccinfo->{regex};
                    if (my $fd = IO::Dir->new($dir)) {
                        while (defined(my $de = $fd->read)) {
                            if ($de =~ m/^$re$/) {
                                my $fn = "$dir/$de";
                                $versions->{$fn}++; # init with version
                                #print "init:$fn:$versions->{$fn}\n";
                            }
                        }
                    }
                }
            } else {
                my $fn = $dirhash->{$dir}->{$name};
                $versions->{$fn}++; # init with version
                #print "init:$fn:$versions->{$fn}\n";
            }
        }
    }
}

my $cached_nodename;

sub nodename {
    return $cached_nodename if $cached_nodename;

    my ($sysname, $nodename) = POSIX::uname();
    $nodename =~ s/\..*$//; # strip domain part, if any

    die "unable to read node name\n" if !$nodename;

    $cached_nodename = $nodename;

    return $cached_nodename;
}

sub read_etc_hostname {
    my ($filename, $fd) = @_;

    my $hostname = <$fd>;

    chomp $hostname;

    $hostname =~ s/\..*$//; # strip domain part, if any

    return $hostname;
}

sub write_etc_hostname {
    my ($filename, $fh, $hostname) = @_;

    die "write failed: $!" unless print $fh "$hostname\n";

    return $hostname;
}

register_file('hostname', "/etc/hostname", \&read_etc_hostname, \&write_etc_hostname);

sub read_etc_hosts {
    my ($filename, $fh) = @_;

    my $raw = '';
    my $data = '';

    while (my $line = <$fh>) {
        $raw .= $line;
        if ($line =~ m/^\s*#/) {
            $line = decode('UTF-8', $line);
        }
        $data .= $line;
    }

    return {
        digest => Digest::SHA::sha1_hex($raw),
        data => $data,
    };
}

sub write_etc_hosts {
    my ($filename, $fh, $hosts, @args) = @_;

    # check validity of ips/names
    for my $line (split("\n", $hosts)) {
        next if $line =~ m/^\s*#/; # comments
        next if $line =~ m/^\s*$/; # whitespace/empty lines

        my ($ip, @names) = split(/\s+/, $line);

        raise_param_exc({ 'data' => "Invalid IP '$ip'" })
            if $ip !~ m/^$PVE::Tools::IPRE$/;

        for my $name (@names) {
            raise_param_exc({ 'data' => "Invalid Hostname '$name'" })
                if $name !~ m/^[.\-a-zA-Z0-9]+$/;
        }
    }

    die "write failed: $!" if !print $fh encode('UTF-8', $hosts);

    return $hosts;
}

register_file('etchosts', "/etc/hosts", \&read_etc_hosts, \&write_etc_hosts);

sub read_etc_resolv_conf {
    my ($filename, $fh) = @_;

    my $res = {};

    my $nscount = 0;
    while (my $line = <$fh>) {
        chomp $line;
        if ($line =~ m/^(search|domain)\s+(\S+)\s*/) {
            $res->{search} = $2;
        } elsif ($line =~ m/^\s*nameserver\s+($PVE::Tools::IPRE)\s*/) {
            $nscount++;
            if ($nscount <= 3) {
                $res->{"dns$nscount"} = $1;
            }
        }
    }

    return $res;
}

sub update_etc_resolv_conf {
    my ($filename, $fh, $resolv, @args) = @_;

    my $data = "";

    $data = "search $resolv->{search}\n"
        if $resolv->{search};

    my $written = {};
    foreach my $k ("dns1", "dns2", "dns3") {
        my $ns = $resolv->{$k};
        if ($ns && $ns ne '0.0.0.0' && !$written->{$ns}) {
            $written->{$ns} = 1;
            $data .= "nameserver $ns\n";
        }
    }

    while (my $line = <$fh>) {
        next if $line =~ m/^(search|domain|nameserver)\s+/;
        $data .= $line;
    }

    return $data;
}

register_file(
    'resolvconf', "/etc/resolv.conf", \&read_etc_resolv_conf, undef, \&update_etc_resolv_conf,
);

# Deprecated: use PVE::Systemd::get_timezone() instead
sub read_etc_timezone {
    my ($filename, $fd) = @_;

    my $timezone = <$fd>;

    chomp $timezone;

    return $timezone;
}

# Deprecated: use PVE::Systemd::set_timezone($timezone) instead
sub write_etc_timezone {
    my ($filename, $fh, $timezone) = @_;

    my $tzinfo = "/usr/share/zoneinfo/$timezone";

    raise_param_exc({ 'timezone' => "No such timezone" })
        if (!-f $tzinfo);

    ($timezone) = $timezone =~ m/^(.*)$/; # untaint

    print $fh "$timezone\n";

    unlink("/etc/localtime");
    symlink("/usr/share/zoneinfo/$timezone", "/etc/localtime");

}

register_file('timezone', "/etc/timezone", \&read_etc_timezone, \&write_etc_timezone);

sub read_active_workers {
    my ($filename, $fh) = @_;

    return [] if !$fh;

    my $res = [];
    while (defined(my $line = <$fh>)) {
        if ($line =~ m/^(\S+)\s(0|1)(\s([0-9A-Za-z]{8})(\s(\s*\S.*))?)?$/) {
            my $upid = $1;
            my $saved = $2;
            my $endtime = $4;
            my $status = $6;
            if ((my $task = PVE::UPID::decode($upid, 1))) {
                $task->{upid} = $upid;
                $task->{saved} = $saved;
                $task->{endtime} = hex($endtime) if $endtime;
                $task->{status} = $status if $status;
                push @$res, $task;
            }
        } else {
            warn "unable to parse line: $line";
        }
    }

    return $res;

}

sub write_active_workers {
    my ($filename, $fh, $tasklist) = @_;

    my $raw = '';
    foreach my $task (@$tasklist) {
        my $upid = $task->{upid};
        my $saved = $task->{saved} ? 1 : 0;
        if ($task->{endtime}) {
            if ($task->{status}) {
                $raw .=
                    sprintf("%s %s %08X %s\n", $upid, $saved, $task->{endtime}, $task->{status});
            } else {
                $raw .= sprintf("%s %s %08X\n", $upid, $saved, $task->{endtime});
            }
        } else {
            $raw .= "$upid $saved\n";
        }
    }

    PVE::Tools::safe_print($filename, $fh, $raw) if $raw;
}

register_file('active', "/var/log/pve/tasks/active", \&read_active_workers, \&write_active_workers);

register_file(
    'interfaces',
    "/etc/network/interfaces",
    \&PVE::Network::Interfaces::read_etc_network_interfaces,
    \&PVE::Network::Interfaces::write_etc_network_interfaces,
);

# Backwards compatibility: these subs used to live here before being split out
# into PVE::Network::Interfaces. Keep the fully-qualified names working for
# external callers that reach in directly instead of going through read_file().
sub read_etc_network_interfaces {
    return PVE::Network::Interfaces::read_etc_network_interfaces(@_);
}

sub write_etc_network_interfaces {
    return PVE::Network::Interfaces::write_etc_network_interfaces(@_);
}

sub __read_etc_network_interfaces {
    return PVE::Network::Interfaces::__read_etc_network_interfaces(@_);
}

sub __write_etc_network_interfaces {
    return PVE::Network::Interfaces::__write_etc_network_interfaces(@_);
}

sub read_iscsi_initiatorname {
    my ($filename, $fd) = @_;

    while (defined(my $line = <$fd>)) {
        if ($line =~ m/^InitiatorName=(\S+)$/) {
            return $1;
        }
    }

    return 'undefined';
}

register_file('initiatorname', "/etc/iscsi/initiatorname.iscsi", \&read_iscsi_initiatorname);

1;
