package PVE::PTY;

use strict;
use warnings;

use Fcntl;
use POSIX qw(O_RDWR O_NOCTTY);

# Constants

use constant {
    TCGETS     => 0x5401,   # fixed, from asm-generic/ioctls.h
    TCSETS     => 0x5402,   # fixed, from asm-generic/ioctls.h
    TIOCGWINSZ => 0x5413,   # fixed, from asm-generic/ioctls.h
    TIOCSWINSZ => 0x5414,   # fixed, from asm-generic/ioctls.h
    TIOCSCTTY  => 0x540E,   # fixed, from asm-generic/ioctls.h
    TIOCNOTTY  => 0x5422,   # fixed, from asm-generic/ioctls.h
    TIOCGPGRP  => 0x540F,   # fixed, from asm-generic/ioctls.h
    TIOCSPGRP  => 0x5410,   # fixed, from asm-generic/ioctls.h

    # IOC: dir:2 size:14 type:8 nr:8
    # Get pty number: dir=2 size=4 type='T' nr=0x30
    TIOCGPTN => 0x80045430,

    # Set pty lock: dir=1 size=4 type='T' nr=0x31
    TIOCSPTLCK => 0x40045431,

    # Send signal: dir=1 size=4 type='T' nr=0x36
    TIOCSIG => 0x40045436,

    # c_cc indices:
    VINTR => 0,
    VQUIT => 1,
    VERASE => 2,
    VKILL => 3,
    VEOF => 4,
    VTIME => 5,
    VMIN => 6,
    VSWTC => 7,
    VSTART => 8,
    VSTOP => 9,
    VSUSP => 10,
    VEOL => 11,
    VREPRINT => 12,
    VDISCARD => 13,
    VWERASE => 14,
    VLNEXT => 15,
    VEOL2 => 16,
};

# Utility functions

sub createpty() {
    # Open the master file descriptor:
    sysopen(my $master, '/dev/ptmx', O_RDWR | O_NOCTTY)
	or die "failed to create pty: $!\n";

    # Find the tty number
    my $ttynum = pack('L', 0);
    ioctl($master, TIOCGPTN, $ttynum)
	or die "failed to query pty number: $!\n";
    $ttynum = unpack('L', $ttynum);

    # Get the slave name/path
    my $ttyname = "/dev/pts/$ttynum";

    # Unlock
    my $false = pack('L', 0);
    ioctl($master, TIOCSPTLCK, $false)
	or die "failed to unlock pty: $!\n";

    return ($master, $ttyname);
}

my $openslave = sub {
    my ($ttyname) = @_;

    # Create a slave file descriptor:
    sysopen(my $slave, $ttyname, O_RDWR | O_NOCTTY)
	or die "failed to open slave pty handle: $!\n";
    return $slave;
};

sub lose_controlling_terminal() {
    # Can we open our current terminal?
    if (sysopen(my $ttyfd, '/dev/tty', O_RDWR)) {
	# Disconnect:
	ioctl($ttyfd, TIOCNOTTY, 0)
	    or die "failed to disconnect controlling tty: $!\n";
	close($ttyfd);
    }
}

sub termios(%) {
    my (%termios) = @_;
    my $cc = $termios{cc} // [];
    if (@$cc < 19) {
	push @$cc, (0) x (19-@$cc);
    } elsif (@$cc > 19) {
	@$cc = $$cc[0..18];
    }

    return pack('LLLLCC[19]',
	$termios{iflag} || 0,
	$termios{oflag} || 0,
	$termios{cflag} || 0,
	$termios{lflag} || 0,
	$termios{line} || 0,
	@$cc);
}

my $parse_termios = sub {
    my ($blob) = @_;
    my ($iflag, $oflag, $cflag, $lflag, $line, @cc) =
    unpack('LLLLCC[19]', $blob);
    return {
	iflag => $iflag,
	oflag => $oflag,
	cflag => $cflag,
	lflag => $lflag,
	line => $line,
	cc => \@cc
    };
};

sub cfmakeraw($) {
    my ($termios) = @_;
    $termios->{iflag} &=
	~(POSIX::IGNBRK | POSIX::BRKINT | POSIX::PARMRK | POSIX::ISTRIP |
	  POSIX::INLCR | POSIX::IGNCR | POSIX::ICRNL | POSIX::IXON);
    $termios->{oflag} &= ~POSIX::OPOST;
    $termios->{lflag} &=
	~(POSIX::ECHO | POSIX::ECHONL | POSIX::ICANON | POSIX::ISIG |
	  POSIX::IEXTEN);
    $termios->{cflag} &= ~(POSIX::CSIZE | POSIX::PARENB);
    $termios->{cflag} |= POSIX::CS8;
}

sub tcgetattr($) {
    my ($fd) = @_;
    my $blob = termios();
    ioctl($fd, TCGETS, $blob) or die "failed to get terminal attributes\n";
    return $parse_termios->($blob);
}

sub tcsetattr($$) {
    my ($fd, $termios) = @_;
    my $blob = termios(%$termios);
    ioctl($fd, TCSETS, $blob) or die "failed to set terminal attributes\n";
}

# tcgetsize -> (columns, rows)
sub tcgetsize($) {
	my ($fd) = @_;
	my $struct_winsz = pack('SSSS', 0, 0, 0, 0);
	ioctl($fd, TIOCGWINSZ, $struct_winsz)
		or die "failed to get window size: $!\n";
	return reverse unpack('SS', $struct_winsz);
}

sub tcsetsize($$$) {
    my ($fd, $columns, $rows) = @_;
    my $struct_winsz = pack('SSSS', $rows, $columns, 0, 0);
    ioctl($fd, TIOCSWINSZ, $struct_winsz)
	or die "failed to set window size: $!\n";
}

sub read_password($;$$) {
    my ($query, $infd, $outfd) = @_;

    my $password = '';

    $infd //= \*STDIN;

    if (!-t $infd) { # Not a terminal? Then just get a line...
	local $/ = "\n";
	$password = <$infd>;
	die "EOF while reading password\n" if !defined $password;
	chomp $password; # Chop off the newline
	return $password;
    }

    $outfd //= \*STDOUT;

    # Raw read loop:
    my $old_termios;
    $old_termios = tcgetattr($infd);
    my $raw_termios = {%$old_termios};
    cfmakeraw($raw_termios);
    tcsetattr($infd, $raw_termios);
    eval {
	my $echo = undef;
	my ($ch, $got);
	syswrite($outfd, $query, length($query));
	while (($got = sysread($infd, $ch, 1))) {
	    my ($ord) = unpack('C', $ch);
	    last if $ord == 4; # ^D / EOF
	    if ($ord == 0xA || $ord == 0xD) {
		# newline, we're done
		syswrite($outfd, "\r\n", 2);
		last;
	    } elsif ($ord == 3) { # ^C
		die "password input aborted\n";
	    } elsif ($ord == 0x7f) {
		# backspace - if it's the first key disable
		# asterisks
		$echo //= 0;
		if (length($password)) {
		    chop $password;
		    syswrite($outfd, "\b \b", 3);
		}
	    } elsif ($ord == 0x09) {
		# TAB disables the asterisk-echo
		$echo = 0;
	    } else {
		# other character, append to password, if it's
		# the first character enable asterisks echo
		$echo //= 1;
		$password .= $ch;
		syswrite($outfd, '*', 1) if $echo;
	    }
	}
	die "read error: $!\n" if !defined($got);
    };
    my $err = $@;
    tcsetattr($infd, $old_termios);
    die $err if $err;
    return $password;
}

sub get_confirmed_password {
    my $pw1 = read_password('Enter new password: ');
    my $pw2 = read_password('Retype new password: ');
    die "passwords do not match\n" if $pw1 ne $pw2;
    return $pw1;
}

# Class functions

sub new {
    my ($class) = @_;

    my ($master, $ttyname) = createpty();

    my $self = {
	master => $master,
	ttyname => $ttyname,
    };

    return bless $self, $class;
}

# Properties

sub master  { return $_[0]->{master}  }
sub ttyname { return $_[0]->{ttyname} }

# Methods

sub close {
    my ($self) = @_;
    close($self->{master});
}

sub open_slave {
    my ($self) = @_;
    return $openslave->($self->{ttyname});
}

sub set_size {
    my ($self, $columns, $rows) = @_;
    tcsetsize($self->{master}, $columns, $rows);
}

# get_size -> (columns, rows)
sub get_size {
    my ($self) = @_;
    return tcgetsize($self->{master});
}

sub kill {
    my ($self, $signal) = @_;
    if (!ioctl($self->{master}, TIOCSIG, $signal)) {
	# kill fallback if the ioctl does not work
	kill $signal, $self->get_foreground_pid()
	    or die "failed to send signal: $!\n";
    }
}

sub get_foreground_pid {
    my ($self) = @_;
    my $pid = pack('L', 0);
    ioctl($self->{master}, TIOCGPGRP, $pid)
	or die "failed to get foreground pid: $!\n";
    return unpack('L', $pid);
}

sub has_process {
    my ($self) = @_;
    return 0 != $self->get_foreground_pid();
}

sub make_controlling_terminal {
    my ($self) = @_;

    #lose_controlling_terminal();
    POSIX::setsid();
    my $slave = $self->open_slave();
    ioctl($slave, TIOCSCTTY, 0)
	or die "failed to change controlling tty: $!\n";
    POSIX::dup2(fileno($slave), 0) or die "failed to dup stdin\n";
    POSIX::dup2(fileno($slave), 1) or die "failed to dup stdout\n";
    POSIX::dup2(fileno($slave), 2) or die "failed to dup stderr\n";
    CORE::close($slave) if fileno($slave) > 2;
    CORE::close($self->{master});
}

sub getattr {
    my ($self) = @_;
    return tcgetattr($self->{master});
}

sub setattr {
    my ($self, $termios) = @_;
    return tcsetattr($self->{master}, $termios);
}

sub send_cc {
    my ($self, $ccidx) = @_;
    my $attrs = $self->getattr();
    my $data = pack('C', $attrs->{cc}->[$ccidx]);
    syswrite($self->{master}, $data)
    == 1 || die "write failed: $!\n";
}

sub send_eof {
    my ($self) = @_;
    $self->send_cc(VEOF);
}

sub send_interrupt {
    my ($self) = @_;
    $self->send_cc(VINTR);
}

1;
