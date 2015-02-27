package PVE::AtomicFile;

use strict;
use warnings;
use IO::AtomicFile;
use vars qw(@ISA);

@ISA = qw(IO::AtomicFile);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    $self;
}


sub DESTROY {
    # dont close atomatically (explicit close required to commit changes)
}
