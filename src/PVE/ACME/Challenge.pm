package PVE::ACME::Challenge;

use strict;
use warnings;

sub supported_challenge_types {
    return {};
}

sub setup {
    my ($class, $acme, $authorization) = @_;

    die "implement me\n";
}

sub teardown {
    my ($self) = @_;

    die "implement me\n";
}

1;
