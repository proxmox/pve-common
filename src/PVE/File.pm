package PVE::File;

use v5.36;

use IO::File qw(O_CREAT O_DIRECTORY O_EXCL O_RDWR O_WRONLY);
use IO::Dir ();
use POSIX qw(EEXIST EOPNOTSUPP);

use base 'Exporter';

our @EXPORT_OK = qw(
    file_set_contents
    file_get_contents
    file_read_first_line
    dir_glob_regex
    dir_glob_foreach
    file_copy
    O_PATH
    O_TMPFILE
    AT_EMPTY_PATH
    AT_FDCWD
);

use constant {
    O_PATH => 0x00200000,
    O_CLOEXEC => 0x00080000,
    O_TMPFILE => 0x00400000 | O_DIRECTORY,
};

use constant {
    AT_EMPTY_PATH => 0x1000,
    AT_FDCWD => -100,
};

# from <linux/fs.h>
use constant {
    RENAME_NOREPLACE => (1 << 0),
    RENAME_EXCHANGE => (1 << 1),
    RENAME_WHITEOUT => (1 << 2),
};

sub file_set_contents {
    my ($filename, $data, $perm, $force_utf8) = @_;

    $perm = 0644 if !defined($perm);

    my $tmpname = "$filename.tmp.$$";

    eval {
        my ($fh, $tries) = (undef, 0);
        while (!$fh && $tries++ < 3) {
            $fh = IO::File->new($tmpname, O_WRONLY | O_CREAT | O_EXCL, $perm);
            if (!$fh && $! == EEXIST) {
                unlink($tmpname) or die "unable to delete old temp file: $!\n";
            }
        }
        die "unable to open file '$tmpname' - $!\n" if !$fh;

        if ($force_utf8) {
            $data = encode("utf8", $data);
        } else {
            # Encode wide characters with print before passing them to syswrite
            my $unencoded_data = $data;
            # Preload PerlIO::scalar at compile time to prevent runtime loading issues when
            # file_set_contents is called with PVE::LXC::Setup::protected_call. Normally,
            # PerlIO::scalar is loaded implicitly during the execution of
            # `open(my $data_fh, '>', \$data)`. However, this fails if it is executed within a
            # chroot environment where the necessary PerlIO.pm module file is inaccessible.
            # Preloading the module ensures it is available regardless of the execution context.
            use PerlIO::scalar;
            open(my $data_fh, '>', \$data) or die "failed to open in-memory variable - $!\n";
            print $data_fh $unencoded_data;
            close($data_fh);
        }

        my $offset = 0;
        my $len = length($data);

        while ($offset < $len) {
            my $written_bytes = syswrite($fh, $data, $len - $offset, $offset)
                or die "unable to write '$tmpname' - $!\n";
            $offset += $written_bytes;
        }

        close $fh or die "closing file '$tmpname' failed - $!\n";
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

sub file_get_contents($filename, $max) {
    my $fh = IO::File->new($filename, "r") || die "can't open '$filename' - $!\n";

    my $content = safe_read_from($fh, $max, 0, $filename);

    close $fh;

    return $content;
}

sub file_copy($filename, $dst, $max, $perm) {
    file_set_contents($dst, file_get_contents($filename, $max), $perm);
}

sub file_read_first_line($filename) {
    my $fh = IO::File->new($filename, "r");
    if (!$fh) {
        return undef if $! == POSIX::ENOENT;
        die "file '$filename' exists but open for reading failed - $!\n";
    }
    my $res = <$fh>;
    chomp $res if $res;
    $fh->close;
    return $res;
}

sub safe_read_from($fh, $max, $oneline, $filename) {
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

# creates a temporary file that does not shows up on the file system hierarchy.
#
# Uses O_TMPFILE if available, which makes it just an anon inode that never shows up in the FS.
# If O_TMPFILE is not available, which unlikely nowadays (added in 3.11 kernel and all FS relevant
# for us support it) back to open-create + immediate unlink while still holding the file  handle.
#
# TODO: to avoid FS dependent features we could (transparently) switch to memfd_create as backend
sub tempfile($perm, %opts) {
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
sub tempfile_contents($data, $perm, %opts) {
    my $fh = tempfile($perm, %opts);
    eval {
        die "unable to write to tempfile: $!\n" if !print {$fh} $data;
        die "unable to flush to tempfile: $!\n" if !defined($fh->flush());
    };
    if (my $err = $@) {
        close $fh;
        die $err;
    }

    return ("/proc/$$/fd/" . $fh->fileno, $fh);
}

sub dir_glob_regex($dir, $regex) {
    my $dh = IO::Dir->new($dir);
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

sub dir_glob_foreach($dir, $regex, $func) {
    my $dh = IO::Dir->new($dir);
    if (defined $dh) {
        while (defined(my $tmp = $dh->read)) {
            if (my @res = $tmp =~ m/^($regex)$/) {
                $func->(@res);
            }
        }
    }
}

1;
