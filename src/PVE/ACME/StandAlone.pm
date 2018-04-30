package PVE::ACME::StandAlone;

use strict;
use warnings;

use HTTP::Daemon;
use HTTP::Response;

use base qw(PVE::ACME::Challenge);

sub supported_challenge_types {
    return { 'http-01' => 1 };
}

sub setup {
    my ($class, $acme, $authorization) = @_;

    my $challenges = $authorization->{challenges};
    die "no challenges defined in authorization\n" if !$challenges;

    my $http_challenges = [ grep {$_->{type} eq 'http-01'} @$challenges ];
    die "no http-01 challenge defined in authorization\n"
	if ! scalar $http_challenges;

    my $http_challenge = $http_challenges->[0];

    die "no token found in http-01 challenge\n" if !$http_challenge->{token};

    my $key_authorization = $acme->key_authorization($http_challenge->{token});

    my $server = HTTP::Daemon->new(
	LocalPort => 80,
	ReuseAddr => 1,
    ) or die "Failed to initialize HTTP daemon\n";
    my $pid = fork() // die "Failed to fork HTTP daemon - $!\n";
    if ($pid) {
	my $self = {
	    server => $server,
	    pid => $pid,
	    authorization => $authorization,
	    key_auth => $key_authorization,
	    url => $http_challenge->{url},
	};

	return bless $self, $class;
    } else {
	while (my $c = $server->accept()) {
	    while (my $r = $c->get_request()) {
		if ($r->method() eq 'GET' and $r->uri->path eq "/.well-known/acme-challenge/$http_challenge->{token}") {
		    my $resp = HTTP::Response->new(200, 'OK', undef, $key_authorization);
		    $resp->request($r);
		    $c->send_response($resp);
		} else {
		    $c->send_error(404, 'Not found.')
		}
	    }
	    $c->close();
	    $c = undef;
	}
    }
}

sub teardown {
    my ($self) = @_;

    eval { $self->{server}->close() };
    kill('KILL', $self->{pid});
    waitpid($self->{pid}, 0);
}

1;
