package PVE::Seccomp;

use v5.36;
use base 'Exporter';

use PVE::Syscall;

# Partial support for seccomp filtering.

our @EXPORT_OK = qw(
    stmt
    set_no_new_privs
    set_filter

    BPF_LD
    BPF_LDX
    BPF_ST
    BPF_STX
    BPF_ALU
    BPF_JMP
    BPF_RET
    BPF_MISC

    BPF_W
    BPF_H
    BPF_B

    BPF_IMM
    BPF_ABS
    BPF_IND
    BPF_MEM
    BPF_LEN
    BPF_MSH

    BPF_JA
    BPF_JEQ
    BPF_JGT
    BPF_JGE
    BPF_JSET

    BPF_K
    BPF_X

    BPF_RET_ALLOW
    BPF_RET_KILL
);

use constant {
    # from /usr/include/linux/bpf_common.h
    BPF_LD => 0x00,
    BPF_LDX => 0x01,
    BPF_ST => 0x02,
    BPF_STX => 0x03,
    BPF_ALU => 0x04,
    BPF_JMP => 0x05,
    BPF_RET => 0x06,
    BPF_MISC => 0x07,

    # sizes
    BPF_W => 0x00, # 32-bit
    BPF_H => 0x08, # 16-bit
    BPF_B => 0x10, # 8-bit

    # modes
    BPF_IMM => 0x00,
    BPF_ABS => 0x20,
    BPF_IND => 0x40,
    BPF_MEM => 0x60,
    BPF_LEN => 0x80,
    BPF_MSH => 0xa0,

    # jump types
    BPF_JA => 0x00,
    BPF_JEQ => 0x10,
    BPF_JGT => 0x20,
    BPF_JGE => 0x30,
    BPF_JSET => 0x40,

    # sources
    BPF_K => 0x00,
    BPF_X => 0x08,

    # from /usr/include/linux/seccomp.h
    BPF_RET_ALLOW => 0x7fff0000,
    BPF_RET_KILL => 0,
};

sub set_no_new_privs : prototype() () {
    # PR_SET_NO_NEW_PRIVS
    if (0 != syscall(PVE::Syscall::prctl, 38, 1, 0, 0, 0)) {
        die "failed to set the no_new_privs process bit: $!\n";
    }
    return;
}

# building block for filters
# This is a `struct sock_filter` from `/usr/include/linux/filter.h`
sub stmt {
    my ($code, $jt, $jf, $k) = @_;
    return pack('SCCL', $code, $jt, $jf, $k);
}

# Build a `struct sock_fprog` from `/usr/include/linux/filter.h`
my sub sock_fprog($len, $filter) {
    return pack('S! x![P] P', $len, $filter);
}

# Takes the program as an array of statements generated with `stmt()` above.
sub set_filter($program) {
    my $binray = join('', @$program);
    my $filter = sock_fprog(scalar(@$program), $binray);

    if (0 != syscall(PVE::Syscall::seccomp, 1, 0, $filter)) {
        die "failed to enter seccomp sandbox: $!\n";
    }

    return;
}

1;
