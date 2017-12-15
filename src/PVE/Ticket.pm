package PVE::Ticket;

use strict;
use warnings;

use Crypt::OpenSSL::Random;
use Crypt::OpenSSL::RSA;
use MIME::Base64;
use Digest::SHA;
use Time::HiRes qw(gettimeofday);

use PVE::Exception qw(raise);

Crypt::OpenSSL::RSA->import_random_seed();

use constant HTTP_UNAUTHORIZED => 401;

sub assemble_csrf_prevention_token {
    my ($secret, $username) = @_;

    my $timestamp = sprintf("%08X", time());

    my $digest = Digest::SHA::sha1_base64("$timestamp:$username", $secret);

    return "$timestamp:$digest";
}

sub verify_csrf_prevention_token {
    my ($secret, $username, $token, $min_age, $max_age, $noerr) = @_;

    if ($token =~ m/^([A-Z0-9]{8}):(\S+)$/) {
	my $sig = $2;
	my $timestamp = $1;
	my $ttime = hex($timestamp);

	my $digest = Digest::SHA::sha1_base64("$timestamp:$username", $secret);

	my $age = time() - $ttime;
	return 1 if ($digest eq $sig) && ($age > $min_age) &&
	    ($age < $max_age);
    }

    raise("Permission denied - invalid csrf token\n", code => HTTP_UNAUTHORIZED)
	if !$noerr;

    return undef;
}

# Note: data may not contain white spaces (verify fails in that case)
sub assemble_rsa_ticket {
    my ($rsa_priv, $prefix, $data, $secret_data) = @_;

    my $timestamp = sprintf("%08X", time());

    my $plain = "$prefix:";

    $plain .= "$data:" if defined($data);

    $plain .= $timestamp;

    my $full = defined($secret_data) ? "$plain:$secret_data" : $plain;

    my $ticket = $plain . "::" . encode_base64($rsa_priv->sign($full), '');

    return $ticket;
}

sub verify_rsa_ticket {
    my ($rsa_pub, $prefix, $ticket, $secret_data, $min_age, $max_age, $noerr) = @_;

    if ($ticket && $ticket =~ m/^(\Q$prefix\E:\S+)::([^:\s]+)$/) {
	my $plain = $1;
	my $sig = $2;

	my $full = defined($secret_data) ? "$plain:$secret_data" : $plain;

	if ($rsa_pub->verify($full, decode_base64($sig))) {
	    if ($plain =~ m/^\Q$prefix\E:(?:(\S+):)?([A-Z0-9]{8})$/) {
		my $data = $1; # Note: not all tickets contains data
		my $timestamp = $2;
		my $ttime = hex($timestamp);

		my $age = time() - $ttime;

		if (($age > $min_age) && ($age < $max_age)) {
		    if (defined($data)) {
			return wantarray ? ($data, $age) : $data;
		    } else {
			return wantarray ? (1, $age) : 1;
		    }
		}
	    }
	}
    }

    raise("permission denied - invalid $prefix ticket\n", code => HTTP_UNAUTHORIZED)
	if !$noerr;

    return undef;
}

sub assemble_spice_ticket {
    my ($secret, $username, $vmid, $node) = @_;

    my ($seconds, $microseconds) = gettimeofday;

    my $timestamp = sprintf("%08x", $seconds);

    my $randomstr = "PVESPICE:$timestamp:$username:$vmid:$node:$secret:" .
	':' . sprintf("%08x", $microseconds) .
	':' . sprintf("%08x", $$) .
	':' . rand(1);

    # this should be used as one-time password
    # max length is 60 chars (spice limit)
    # we pass this to qemu set_pasword and limit lifetime there
    # keep this secret
    my $ticket = Digest::SHA::sha1_hex($randomstr);

    # Note: spice proxy connects with HTTP, so $proxyticket is exposed to public
    # we use a signature/timestamp to make sure nobody can fake such a ticket
    # an attacker can use this $proxyticket, but he will fail because $ticket is
    # private.
    # The proxy needs to be able to extract/verify the ticket
    # Note: data needs to be lower case only, because virt-viewer needs that
    # Note: RSA signature are too long (>=256 charaters) and make problems with remote-viewer

    my $plain = "pvespiceproxy:$timestamp:$vmid:" . lc($node);

    # produces 40 characters
    my $sig = unpack("H*", Digest::SHA::sha1($plain, $secret));

    #my $sig =  unpack("H*", $rsa_priv->sign($plain)); # this produce too long strings (512)

    my $proxyticket = "$plain::$sig";

    return ($ticket, $proxyticket);
}

sub verify_spice_connect_url {
    my ($secret, $connect_str) = @_;

    # Note: we pass the spice ticket as 'host', so the
    # spice viewer connects with "$ticket:$port"

    return undef if !$connect_str;

    if ($connect_str =~m/^pvespiceproxy:([a-z0-9]{8}):(\d+):(\S+)::([a-z0-9]{40}):(\d+)$/) {
	my ($timestamp, $vmid, $node, $hexsig, $port) = ($1, $2, $3, $4, $5, $6);
	my $ttime = hex($timestamp);
	my $age = time() - $ttime;

	# use very limited lifetime - is this enough?
	return undef if !(($age > -20) && ($age < 40));

	my $plain = "pvespiceproxy:$timestamp:$vmid:$node";
	my $sig = unpack("H*", Digest::SHA::sha1($plain, $secret));

	if ($sig eq $hexsig) {
	    return ($vmid, $node, $port);
	}
    }

    return undef;
}

1;
