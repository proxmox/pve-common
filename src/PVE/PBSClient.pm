package PVE::PBSClient;
# utility functions for interaction with Proxmox Backup client CLI executable

use strict;
use warnings;

use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC);
use IO::File;
use JSON;
use POSIX qw(strftime ENOENT);

use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(run_command file_set_contents file_get_contents file_read_firstline);

sub new {
    my ($class, $scfg, $storeid, $sdir) = @_;

    die "no section config provided\n" if ref($scfg) eq '';
    die "undefined store id\n" if !defined($storeid);

    my $secret_dir = $sdir // '/etc/pve/priv/storage';

    my $self = bless {
	scfg => $scfg,
	storeid => $storeid,
	secret_dir => $secret_dir
    }, $class;
    return $self;
}

my sub password_file_name {
    my ($self) = @_;

    return "$self->{secret_dir}/$self->{storeid}.pw";
}

sub set_password {
    my ($self, $password) = @_;

    my $pwfile = password_file_name($self);
    mkdir $self->{secret_dir};

    PVE::Tools::file_set_contents($pwfile, "$password\n", 0600);
};

sub delete_password {
    my ($self) = @_;

    my $pwfile = password_file_name($self);

    unlink $pwfile or die "deleting password file failed - $!\n";
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
    mkdir $self->{secret_dir};

    PVE::Tools::file_set_contents($encfile, "$key\n", 0600);
};

sub delete_encryption_key {
    my ($self) = @_;

    my $encfile = $self->encryption_key_file_name();

    if (!unlink $encfile) {
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
    backup => 1,
    restore => 1,
    'upload-log' => 1,
};

my sub do_raw_client_cmd {
    my ($self, $client_cmd, $param, %opts) = @_;

    my $use_crypto = $USE_CRYPT_PARAMS->{$client_cmd};

    my $client_exe = '/usr/bin/proxmox-backup-client';
    die "executable not found '$client_exe'! Proxmox backup client not installed?\n"
	if ! -x $client_exe;

    my $scfg = $self->{scfg};
    my $server = $scfg->{server};
    my $datastore = $scfg->{datastore};
    my $username = $scfg->{username} // 'root@pam';

    my $userns_cmd = delete $opts{userns_cmd};

    my $cmd = [];

    push @$cmd, @$userns_cmd if defined($userns_cmd);

    push @$cmd, $client_exe, $client_cmd;

    # This must live in the top scope to not get closed before the `run_command`
    my $keyfd;
    if ($use_crypto) {
	if (defined($keyfd = open_encryption_key($self))) {
	    my $flags = fcntl($keyfd, F_GETFD, 0)
		// die "failed to get file descriptor flags: $!\n";
	    fcntl($keyfd, F_SETFD, $flags & ~FD_CLOEXEC)
		or die "failed to remove FD_CLOEXEC from encryption key file descriptor\n";
	    push @$cmd, '--crypt-mode=encrypt', '--keyfd='.fileno($keyfd);
	} else {
	    push @$cmd, '--crypt-mode=none';
	}
    }

    push @$cmd, @$param if defined($param);

    push @$cmd, "--repository", "$username\@$server:$datastore";

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

my sub run_raw_client_cmd {
    my ($self, $client_cmd, $param, %opts) = @_;
    return do_raw_client_cmd($self, $client_cmd, $param, %opts);
}

my sub run_client_cmd {
    my ($self, $client_cmd, $param, $no_output) = @_;

    my $json_str = '';
    my $outfunc = sub { $json_str .= "$_[0]\n" };

    $param = [] if !defined($param);
    $param = [ $param ] if !ref($param);

    $param = [@$param, '--output-format=json'] if !$no_output;

    do_raw_client_cmd(
        $self,
        $client_cmd,
        $param,
        outfunc => $outfunc,
        errmsg => 'proxmox-backup-client failed'
    );

    return undef if $no_output;

    my $res = decode_json($json_str);

    return $res;
}

sub autogen_encryption_key {
    my ($self) = @_;
    my $encfile = $self->encryption_key_file_name();
    run_command(
        ['proxmox-backup-client', 'key', 'create', '--kdf', 'none', $encfile],
        errmsg => 'failed to create encryption key'
    );
    return file_get_contents($encfile);
};

# lists all snapshots, optionally limited to a specific group
sub get_snapshots {
    my ($self, $group) = @_;

    my $param = [];
    push @$param, $group if defined($group);

    return run_client_cmd($self, "snapshots", $param);
};

sub backup_tree {
    my ($self, $opts) = @_;

    my $type = delete $opts->{type};
    die "backup-type not provided\n" if !defined($type);
    my $id = delete $opts->{id};
    die "backup-id not provided\n" if !defined($id);
    my $root = delete $opts->{root};
    die "root dir not provided\n" if !defined($root);
    my $pxarname = delete $opts->{pxarname};
    die "archive name not provided\n" if !defined($pxarname);
    my $time = delete $opts->{time};

    my $param = [
	"$pxarname.pxar:$root",
	'--backup-type', $type,
	'--backup-id', $id,
    ];
    push @$param, '--backup-time', $time if defined($time);

    return run_raw_client_cmd($self, 'backup', $param, %$opts);
};

sub restore_pxar {
    my ($self, $snapshot, $pxarname, $target, $cmd_opts) = @_;

    die "snapshot not provided\n" if !defined($snapshot);
    die "archive name not provided\n" if !defined($pxarname);
    die "restore-target not provided\n" if !defined($target);

    my $param = [
	"$snapshot",
	"$pxarname.pxar",
	"$target",
	"--allow-existing-dirs", 0,
    ];
    $cmd_opts //= {};

    return run_raw_client_cmd($self, 'restore', $param, %$cmd_opts);
};

sub forget_snapshot {
    my ($self, $snapshot) = @_;

    die "snapshot not provided\n" if !defined($snapshot);

    return run_raw_client_cmd($self, 'forget', ["$snapshot"]);
};

sub prune_group {
    my ($self, $opts, $prune_opts, $group) = @_;

    die "group not provided\n" if !defined($group);

    # do nothing if no keep options specified for remote
    return [] if scalar(keys %$prune_opts) == 0;

    my $param = [];

    push @$param, "--quiet";

    if (defined($opts->{'dry-run'}) && $opts->{'dry-run'}) {
	push @$param, "--dry-run", $opts->{'dry-run'};
    }

    foreach my $keep_opt (keys %$prune_opts) {
	push @$param, "--$keep_opt", $prune_opts->{$keep_opt};
    }
    push @$param, "$group";

    return run_client_cmd($self, 'prune', $param);
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

1;
