#!/usr/bin/perl

use v5.36;

use lib '../src';

use Crypt::OpenSSL::RSA;
use MIME::Base64;
use Test::More;

use PVE::Ticket;

my $rsa_priv = Crypt::OpenSSL::RSA->generate_key(2048);
my $rsa_pub = Crypt::OpenSSL::RSA->new_public_key($rsa_priv->get_public_key_string());

my sub verify($ticket, $secret_data = undef) {
    return PVE::Ticket::verify_rsa_ticket($rsa_pub, 'PVE', $ticket, $secret_data, -20, 7200, 1);
}

# user names may contain '%', which must not be decoded into something else on verification
for my $data ('root@pam', 'a%b@pve', 'a%41b@pve', 'a%3Ab@pve', 'a%25b@pve', 'a:b', '%') {
    my $ticket = PVE::Ticket::assemble_rsa_ticket($rsa_priv, 'PVE', $data);
    is(verify($ticket), $data, "round trip of '$data'");
}

my $ticket = PVE::Ticket::assemble_rsa_ticket($rsa_priv, 'PVE', undef, 'secret');
is(verify($ticket, 'secret'), 1, "ticket without data");
is(verify($ticket, 'other'), undef, "ticket without data, wrong secret data");

# older versions only escaped ':' when assembling a ticket
my sub assemble_ticket_without_percent_escape($data) {
    my $plain = sprintf("PVE:%s:%08X", $data =~ s/:/%3A/gr, time());
    return "${plain}::" . encode_base64($rsa_priv->sign($plain), '');
}

for my $data ('root@pam', 'a%b@pve', 'a:b') {
    my $ticket = assemble_ticket_without_percent_escape($data);
    is(verify($ticket), $data, "ticket without percent escape for '$data'");
}
for my $data ('a%41b@pve', 'a%6fb@pve') {
    my $ticket = assemble_ticket_without_percent_escape($data);
    is(verify($ticket), undef, "ticket without percent escape for '$data' is rejected");
}

done_testing();
