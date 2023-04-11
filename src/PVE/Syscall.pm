package PVE::Syscall;

use strict;
use warnings;

my %syscalls;
my %fsmount_constants;
BEGIN {
    die "syscall.ph can only be required once!\n" if $INC{'syscall.ph'};
    require("syscall.ph");
    %syscalls = (
	unshare => &SYS_unshare,
	setns => &SYS_setns,
	syncfs => &SYS_syncfs,
	fsync => &SYS_fsync,
	openat => &SYS_openat,
	close => &SYS_close,
	mkdirat => &SYS_mkdirat,
	faccessat => &SYS_faccessat,
	setresuid => &SYS_setresuid,
	fchownat => &SYS_fchownat,
	mount => &SYS_mount,
	renameat2 => &SYS_renameat2,
	open_tree => &SYS_open_tree,
	move_mount => &SYS_move_mount,
	fsopen => &SYS_fsopen,
	fsconfig => &SYS_fsconfig,
	fsmount => &SYS_fsmount,
	fspick => &SYS_fspick,
	getxattr => &SYS_getxattr,
	setxattr => &SYS_setxattr,
	fgetxattr => &SYS_fgetxattr,
	fsetxattr => &SYS_fsetxattr,

	# Below aren't yet in perl's syscall.ph but use asm-generic, so the same across (sane) archs
	# -> none unknown currently, yay
    );

    %fsmount_constants = (
	OPEN_TREE_CLONE   => 0x0000_0001,
	OPEN_TREE_CLOEXEC => 000200_0000, # octal!

	MOVE_MOUNT_F_SYMLINKS   => 0x0000_0001,
	MOVE_MOUNT_F_AUTOMOUNTS => 0x0000_0002,
	MOVE_MOUNT_F_EMPTY_PATH => 0x0000_0004,
	MOVE_MOUNT_F_MASK       => 0x0000_0007,

	MOVE_MOUNT_T_SYMLINKS   => 0x0000_0010,
	MOVE_MOUNT_T_AUTOMOUNTS => 0x0000_0020,
	MOVE_MOUNT_T_EMPTY_PATH => 0x0000_0040,
	MOVE_MOUNT_T_MASK       => 0x0000_0070,

	FSMOUNT_CLOEXEC => 0x0000_0001,

	FSOPEN_CLOEXEC => 0x0000_0001,

	MOUNT_ATTR_RDONLY      => 0x0000_0001,
	MOUNT_ATTR_NOSUID      => 0x0000_0002,
	MOUNT_ATTR_NODEV       => 0x0000_0004,
	MOUNT_ATTR_NOEXEC      => 0x0000_0008,
	MOUNT_ATTR_RELATIME    => 0x0000_0000,
	MOUNT_ATTR_NOATIME     => 0x0000_0010,
	MOUNT_ATTR_STRICTATIME => 0x0000_0020,
	MOUNT_ATTR_NODIRATIME  => 0x0000_0080,

	FSPICK_CLOEXEC          => 0x0000_0001,
	FSPICK_SYMLINK_NOFOLLOW => 0x0000_0002,
	FSPICK_NO_AUTOMOUNT     => 0x0000_0004,
	FSPICK_EMPTY_PATH       => 0x0000_0008,

	FSCONFIG_SET_FLAG        => 0,
	FSCONFIG_SET_STRING      => 1,
	FSCONFIG_SET_BINARY      => 2,
	FSCONFIG_SET_PATH        => 3,
	FSCONFIG_SET_PATH_EMPTY  => 4,
	FSCONFIG_SET_FD          => 5,
	FSCONFIG_CMD_CREATE      => 6,
	FSCONFIG_CMD_RECONFIGURE => 7,
    );
};

use constant \%syscalls;
use constant \%fsmount_constants;

use base 'Exporter';

our @EXPORT_OK = (keys(%syscalls), keys(%fsmount_constants), 'file_handle_result');
our %EXPORT_TAGS = (fsmount => [keys(%fsmount_constants)]);

# Create a file handle from a numeric file descriptor (to make sure it's close()d when it goes out
# of scope).
sub file_handle_result($) {
    my ($fd_num) = @_;
    return undef if $fd_num < 0;

    open(my $fh, '<&=', $fd_num)
	or return undef;

    return $fh;
}

1;
