package PVE::Syscall;

my %syscalls;
BEGIN {
    die "syscall.ph can only be required once!\n" if $INC{'syscall.ph'};
    require("syscall.ph");
    %syscalls = (
	unshare => &SYS_unshare,
	setns => &SYS_setns,
	syncfs => &SYS_syncfs,
	openat => &SYS_openat,
	close => &SYS_close,
	mkdirat => &SYS_mkdirat,
	faccessat => &SYS_faccessat,
    );
};

use constant \%syscalls;

use base 'Exporter';

our @EXPORT_OK   = keys(%syscalls);
