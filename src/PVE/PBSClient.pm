package PVE::PBSClient;
# utility functions for interaction with Proxmox Backup client CLI executable

use strict;
use warnings;

use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC);
use File::Temp qw(tempdir);
use IO::File;
use JSON;
use POSIX qw(mkfifo strftime ENOENT);

use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(run_command file_set_contents file_get_contents file_read_firstline $IPV6RE);

# returns a repository string suitable for proxmox-backup-client, pbs-restore, etc.
# $scfg must have the following structure:
# {
#     datastore
#     server
#     port        (optional defaults to 8007)
#     username    (optional defaults to 'root@pam')
# }
sub get_repository {
    my ($scfg) = @_;

    my $server = $scfg->{server};
    die "no server given\n" if !defined($server);

    $server = "[$server]" if $server =~ /^$IPV6RE$/;

    if (my $port = $scfg->{port}) {
	$server .= ":$port" if $port != 8007;
    }

    my $datastore = $scfg->{datastore};
    die "no datastore given\n" if !defined($datastore);

    my $username = $scfg->{username} // 'root@pam';

    return "$username\@$server:$datastore";
}

sub new {
    my ($class, $scfg, $storeid, $secret_dir) = @_;

    die "no section config provided\n" if ref($scfg) eq '';
    die "undefined store id\n" if !defined($storeid);

    $secret_dir = '/etc/pve/priv/storage' if !defined($secret_dir);

    my $self = bless({
	scfg => $scfg,
	storeid => $storeid,
	secret_dir => $secret_dir
    }, $class);
    return $self;
}

my sub password_file_name {
    my ($self) = @_;

    return "$self->{secret_dir}/$self->{storeid}.pw";
}

sub set_password {
    my ($self, $password) = @_;

    my $pwfile = password_file_name($self);
    mkdir($self->{secret_dir});

    PVE::Tools::file_set_contents($pwfile, "$password\n", 0600);
};

sub delete_password {
    my ($self) = @_;

    my $pwfile = password_file_name($self);

    unlink $pwfile or $! == ENOENT or die "deleting password file failed - $!\n";
};

sub get_password {
    my ($self) = @_;

    my $pwfile = password_file_name($self);

    return PVE::Tools::file_read_firstline($pwfile);
}

sub encryption_key_file_name {
    my ($self) = @_;

    return "$self->{secret_dir}/$self->{storeid}.enc";
};

sub set_encryption_key {
    my ($self, $key) = @_;

    my $encfile = $self->encryption_key_file_name();
    mkdir($self->{secret_dir});

    PVE::Tools::file_set_contents($encfile, "$key\n", 0600);
};

sub delete_encryption_key {
    my ($self) = @_;

    my $encfile = $self->encryption_key_file_name();

    if (!unlink($encfile)) {
	return if $! == ENOENT;
	die "failed to delete encryption key! $!\n";
    }
};

# Returns a file handle if there is an encryption key, or `undef` if there is not. Dies on error.
my sub open_encryption_key {
    my ($self) = @_;

    my $encryption_key_file = $self->encryption_key_file_name();

    my $keyfd;
    if (!open($keyfd, '<', $encryption_key_file)) {
	return undef if $! == ENOENT;
	die "failed to open encryption key: $encryption_key_file: $!\n";
    }

    return $keyfd;
}

my $USE_CRYPT_PARAMS = {
    'proxmox-backup-client' => {
	backup => 1,
	restore => 1,
	'upload-log' => 1,
    },
    'proxmox-file-restore' => {
	list => 1,
	extract => 1,
    },
};

my sub do_raw_client_cmd {
    my ($self, $client_cmd, $param, %opts) = @_;

    my $client_bin = delete($opts{binary}) || 'proxmox-backup-client';
    my $use_crypto = $USE_CRYPT_PARAMS->{$client_bin}->{$client_cmd} // 0;

    my $client_exe = "/usr/bin/$client_bin";
    die "executable not found '$client_exe'! $client_bin not installed?\n" if ! -x $client_exe;

    my $scfg = $self->{scfg};
    my $repo = get_repository($scfg);

    my $userns_cmd = delete($opts{userns_cmd});

    my $cmd = [];

    push(@$cmd, @$userns_cmd) if defined($userns_cmd);

    push(@$cmd, $client_exe, $client_cmd);

    # This must live in the top scope to not get closed before the `run_command`
    my $keyfd;
    if ($use_crypto) {
	if (defined($keyfd = open_encryption_key($self))) {
	    my $flags = fcntl($keyfd, F_GETFD, 0)
		// die "failed to get file descriptor flags: $!\n";
	    fcntl($keyfd, F_SETFD, $flags & ~FD_CLOEXEC)
		or die "failed to remove FD_CLOEXEC from encryption key file descriptor\n";
	    push(@$cmd, '--crypt-mode=encrypt', '--keyfd='.fileno($keyfd));
	} else {
	    push(@$cmd, '--crypt-mode=none');
	}
    }

    push(@$cmd, @$param) if defined($param);

    push(@$cmd, "--repository", $repo);
    if (defined(my $ns = delete($opts{namespace}))) {
	push(@$cmd, '--ns', $ns);
    }

    local $ENV{PBS_PASSWORD} = $self->get_password();

    local $ENV{PBS_FINGERPRINT} = $scfg->{fingerprint};

    # no ascii-art on task logs
    local $ENV{PROXMOX_OUTPUT_NO_BORDER} = 1;
    local $ENV{PROXMOX_OUTPUT_NO_HEADER} = 1;

    if (my $logfunc = $opts{logfunc}) {
	$logfunc->("run: " . join(' ', @$cmd));
    }

    run_command($cmd, %opts);
}

my sub run_raw_client_cmd : prototype($$$%) {
    my ($self, $client_cmd, $param, %opts) = @_;
    return do_raw_client_cmd($self, $client_cmd, $param, %opts);
}

my sub run_client_cmd : prototype($$;$$$$) {
    my ($self, $client_cmd, $param, $no_output, $binary, $namespace) = @_;

    my $json_str = '';
    my $outfunc = sub { $json_str .= "$_[0]\n" };

    $binary = 'proxmox-backup-client' if !defined($binary);

    $param = [] if !defined($param);
    $param = [ $param ] if !ref($param);

    $param = [ @$param, '--output-format=json' ] if !$no_output;

    do_raw_client_cmd(
	$self,
	$client_cmd,
	$param,
	outfunc => $outfunc,
	errmsg => "$binary failed",
	binary => $binary,
	namespace => $namespace,
    );

    return undef if $no_output;

    my $res = decode_json($json_str);

    return $res;
}

sub autogen_encryption_key {
    my ($self) = @_;
    my $encfile = $self->encryption_key_file_name();
    run_command(
        [ 'proxmox-backup-client', 'key', 'create', '--kdf', 'none', $encfile ],
        errmsg => 'failed to create encryption key'
    );
    return file_get_contents($encfile);
};

# TODO remove support for namespaced parameters. Needs Breaks for pmg-api and libpve-storage-perl.
# Deprecated! The namespace should be passed in as part of the config in new().
# Snapshot or group parameters can be either just a string and will then default to the namespace
# that's part of the initial configuration in new(), or a tuple of `[namespace, snapshot]`.
my sub split_namespaced_parameter : prototype($$) {
    my ($self, $snapshot) = @_;
    return ($self->{scfg}->{namespace}, $snapshot) if !ref($snapshot);

    (my $namespace, $snapshot) = @$snapshot;
    return ($namespace, $snapshot);
}

# lists all snapshots, optionally limited to a specific group
sub get_snapshots {
    my ($self, $group) = @_;

    my $namespace;
    if (defined($group)) {
	($namespace, $group) = split_namespaced_parameter($self, $group);
    } else {
	$namespace = $self->{scfg}->{namespace};
    }

    my $param = [];
    push(@$param, $group) if defined($group);

    return run_client_cmd($self, "snapshots", $param, undef, undef, $namespace);
};

# create a new PXAR backup of a FS directory tree - doesn't cross FS boundary
# by default.
sub backup_fs_tree {
    my ($self, $root, $id, $pxarname, $cmd_opts) = @_;

    die "backup-id not provided\n" if !defined($id);
    die "backup root dir not provided\n" if !defined($root);
    die "archive name not provided\n" if !defined($pxarname);

    my $param = [
	"$pxarname.pxar:$root",
	'--backup-type', 'host',
	'--backup-id', $id,
    ];

    $cmd_opts = {} if !defined($cmd_opts);

    if (defined(my $namespace = $self->{scfg}->{namespace})) {
	$cmd_opts->{namespace} = $namespace;
    }

    return run_raw_client_cmd($self, 'backup', $param, %$cmd_opts);
};

sub restore_pxar {
    my ($self, $snapshot, $pxarname, $target, $cmd_opts) = @_;

    die "snapshot not provided\n" if !defined($snapshot);
    die "archive name not provided\n" if !defined($pxarname);
    die "restore-target not provided\n" if !defined($target);

    (my $namespace, $snapshot) = split_namespaced_parameter($self, $snapshot);

    my $param = [
	"$snapshot",
	"$pxarname.pxar",
	"$target",
	"--allow-existing-dirs", 0,
    ];
    $cmd_opts = {} if !defined($cmd_opts);

    $cmd_opts->{namespace} = $namespace;

    return run_raw_client_cmd($self, 'restore', $param, %$cmd_opts);
};

sub forget_snapshot {
    my ($self, $snapshot) = @_;

    die "snapshot not provided\n" if !defined($snapshot);

    (my $namespace, $snapshot) = split_namespaced_parameter($self, $snapshot);

    return run_client_cmd($self, 'forget', [ "$snapshot" ], 1, undef, $namespace)
};

sub prune_group {
    my ($self, $opts, $prune_opts, $group) = @_;

    die "group not provided\n" if !defined($group);

    (my $namespace, $group) = split_namespaced_parameter($self, $group);

    # do nothing if no keep options specified for remote
    return [] if scalar(keys %$prune_opts) == 0;

    my $param = [];

    push(@$param, "--quiet");

    if (defined($opts->{'dry-run'}) && $opts->{'dry-run'}) {
	push(@$param, "--dry-run", $opts->{'dry-run'});
    }

    for my $keep_opt (keys %$prune_opts) {
	push(@$param, "--$keep_opt", $prune_opts->{$keep_opt});
    }
    push(@$param, "$group");

    return run_client_cmd($self, 'prune', $param, undef, undef, $namespace);
};

sub status {
    my ($self) = @_;

    my $total = 0;
    my $free = 0;
    my $used = 0;
    my $active = 0;

    eval {
	my $res = run_client_cmd($self, "status");

	$active = 1;
	$total = $res->{total};
	$used = $res->{used};
	$free = $res->{avail};
    };
    if (my $err = $@) {
	warn $err;
    }

    return ($total, $free, $used, $active);
};

sub file_restore_list {
    my ($self, $snapshot, $filepath, $base64, $extra_params) = @_;

    (my $namespace, $snapshot) = split_namespaced_parameter($self, $snapshot);
    my $cmd = [ $snapshot, $filepath, "--base64", ($base64 ? 1 : 0) ];

    if (my $timeout = $extra_params->{timeout}) {
	push($cmd->@*, '--timeout', $timeout);
    }

    return run_client_cmd(
	$self,
	"list",
	$cmd,
	0,
	"proxmox-file-restore",
	$namespace,
    );
}

# call sync from API, returns a fifo path for streaming data to clients,
# pass it to file_restore_extract to start transfering data
sub file_restore_extract_prepare {
    my ($self) = @_;

    my $tmpdir = tempdir();
    mkfifo("$tmpdir/fifo", 0600)
	or die "creating file download fifo '$tmpdir/fifo' failed: $!\n";

    # allow reading data for proxy user
    my $wwwid = getpwnam('www-data') ||
	die "getpwnam failed";
    chown($wwwid, -1, "$tmpdir")
	or die "changing permission on fifo dir '$tmpdir' failed: $!\n";
    chown($wwwid, -1, "$tmpdir/fifo")
	or die "changing permission on fifo '$tmpdir/fifo' failed: $!\n";

    return "$tmpdir/fifo";
}

# this blocks while data is transfered, call this from a background worker
sub file_restore_extract {
    my ($self, $output_file, $snapshot, $filepath, $base64, $tar) = @_;

    (my $namespace, $snapshot) = split_namespaced_parameter($self, $snapshot);

    my $ret = eval {
	local $SIG{ALRM} = sub { die "got timeout\n" };
	alarm(30);
	sysopen(my $fh, "$output_file", O_WRONLY)
	    or die "open target '$output_file' for writing failed: $!\n";
	alarm(0);

	my $fn = fileno($fh);
	my $errfunc = sub { print $_[0], "\n"; };

	my $cmd = [ $snapshot, $filepath, "-", "--base64", ($base64 ? 1 : 0) ];
	if ($tar) {
	    push(@$cmd, '--format', 'tar', '--zstd', 1);
	}

	return run_raw_client_cmd(
	    $self,
            "extract",
	    $cmd,
	    binary => "proxmox-file-restore",
	    namespace => $namespace,
	    errfunc => $errfunc,
	    output => ">&$fn",
	);
    };
    my $err = $@;

    unlink($output_file);
    $output_file =~ s/fifo$//;
    rmdir($output_file) if -d $output_file;

    die "file restore task failed: $err" if $err;
    return $ret;
}

1;
