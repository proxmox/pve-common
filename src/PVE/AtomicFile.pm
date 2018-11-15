package PVE::AtomicFile;

use strict;
use warnings;
use IO::AtomicFile;

our @ISA = qw(IO::AtomicFile);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    $self;
}


sub DESTROY {
    # don't close atomatically (explicit close required to commit changes)
}
