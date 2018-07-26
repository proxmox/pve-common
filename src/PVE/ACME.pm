package PVE::ACME;

use strict;
use warnings;

use POSIX;

use Data::Dumper;
use Date::Parse;
use MIME::Base64 qw(encode_base64url);
use File::Path qw(make_path);
use JSON;
use Digest::SHA qw(sha256 sha256_hex);

use HTTP::Request;
use LWP::UserAgent;

use Crypt::OpenSSL::RSA;

use PVE::Certificate;
use PVE::Tools qw(
file_set_contents
file_get_contents
);

Crypt::OpenSSL::RSA->import_random_seed();

my $LETSENCRYPT_STAGING = 'https://acme-staging-v02.api.letsencrypt.org/directory';

### ACME library (compatible with Let's Encrypt v2 API)
#
# sample usage:
#
# 1) my $acme = PVE::ACME->new('path/to/account.json', 'API directory URL');
# 2) $acme->init(4096); # generate account key
# 4) my $tos_url = $acme->get_meta()->{termsOfService}; # optional, display if applicable
# 5) $acme->new_account($tos_url, contact => ['mailto:example@example.com']);
#
# 1) my $acme = PVE::ACME->new('path/to/account.json', 'API directory URL');
# 2) $acme->load();
# 3) my ($order_url, $order) = $acme->new_order(['foo.example.com', 'bar.example.com']);
# 4) # repeat a-f for each $auth_url in $order->{authorizations}
# a) my $authorization = $acme->get_authorization($auth_url);
# b) # pick $challenge from $authorization->{challenges} according to desired type
# c) my $key_auth = $acme->key_authorization($challenge->{token});
# d) # setup challenge validation according to specification
# e) $acme->request_challenge_validation($challenge->{url}, $key_auth);
# f) # poll $acme->get_authorization($auth_url) until status is 'valid'
# 5) # generate CSR in PEM format
# 6) $acme->finalize_order($order, $csr);
# 7) # poll $acme->get_order($order_url) until status is 'valid'
# 8) my $cert = $acme->get_certificate($order);
# 9) # $key is path to key file, $cert contains PEM-encoded certificate chain
#
# 1) my $acme = PVE::ACME->new('path/to/account.json', 'API directory URL');
# 2) $acme->load();
# 3) $acme->revoke_certificate($cert);

# Tools
sub encode($) { # acme requires 'base64url' encoding
    return encode_base64url($_[0]);
}

sub tojs($;%) { # shortcut for to_json with utf8=>1
    my ($data, %data) = @_;
    return to_json($data, { utf8 => 1, %data });
}

sub fromjs($) {
    return from_json($_[0]);
}

sub fatal($$;$$) {
    my ($self, $msg, $dump, $noerr) = @_;

    warn Dumper($dump), "\n" if $self->{debug} && $dump;
    if ($noerr) {
	warn "$msg\n";
    } else {
	die "$msg\n";
    }
}

# Implementation

# $path: account JSON file
# $directory: the ACME directory URL used to find method URLs
sub new($$$) {
    my ($class, $path, $directory) = @_;

    $directory //= $LETSENCRYPT_STAGING;

    my $ua = LWP::UserAgent->new();
    $ua->env_proxy();
    $ua->agent('pve-acme/0.1');
    $ua->protocols_allowed(['https']);

    my $self = {
	ua => $ua,
	path => $path,
	directory => $directory,
	nonce => undef,
	key => undef,
	location => undef,
	account => undef,
	tos => undef,
    };

    return bless $self, $class;
}

# RS256: PKCS#1 padding, no OAEP, SHA256
my $configure_key = sub {
    my ($key) = @_;
    $key->use_pkcs1_padding();
    $key->use_sha256_hash();
};

# Create account key with $keybits bits
# use instead of load, overwrites existing account JSON file!
sub init {
    my ($self, $keybits) = @_;
    die "Already have a key\n" if defined($self->{key});
    $keybits //= 4096;
    my $key = Crypt::OpenSSL::RSA->generate_key($keybits);
    $configure_key->($key);
    $self->{key} = $key;
    $self->save();
}

my @SAVED_VALUES = qw(location account tos debug directory);
# Serialize persistent parts of $self to $self->{path} as JSON
sub save {
    my ($self) = @_;
    my $o = {};
    my $keystr;
    if (my $key = $self->{key}) {
	$keystr = $key->get_private_key_string();
	$o->{key} = $keystr;
    }
    for my $k (@SAVED_VALUES) {
	my $v = $self->{$k} // next;
	$o->{$k} = $v;
    }
    # pretty => 1 for readability
    # canonical => 1 to reduce churn
    file_set_contents($self->{path}, tojs($o, pretty => 1, canonical => 1));
}

# Load serialized account JSON file into $self
sub load {
    my ($self) = @_;
    return if $self->{loaded};
    $self->{loaded} = 1;
    my $raw = file_get_contents($self->{path});
    if ($raw =~ m/^(.*)$/s) { $raw = $1; }  # untaint
    my $data = fromjs($raw);
    $self->{$_} = $data->{$_} for @SAVED_VALUES;
    if (defined(my $keystr = $data->{key})) {
	my $key = Crypt::OpenSSL::RSA->new_private_key($keystr);
	$configure_key->($key);
	$self->{key} = $key;
    }
}

# The 'jwk' object needs the key type, key parameters and the usage,
# except for when we want to take the JWK-Thumbprint, then the usage
# must not be included.
sub jwk {
    my ($self, $pure) = @_;
    my $key = $self->{key}
	or die "No key was generated yet\n";
    my ($n, $e) = $key->get_key_parameters();
    return {
	kty => 'RSA',
	($pure ? () : (use => 'sig')), # for thumbprints
	n => encode($n->to_bin),
	e => encode($e->to_bin),
    };
}

# The thumbprint is a sha256 hash of the lexicographically sorted (iow.
# canonical) condensed json string of the JWK object which gets base64url
# encoded.
sub jwk_thumbprint {
    my ($self) = @_;
    my $jwk = $self->jwk(1); # $pure = 1
    return encode(sha256(tojs($jwk, canonical=>1))); # canonical sorts
}

# A key authorization string in acme is a challenge token dot-connected with
# a JWK Thumbprint. You put the base64url encoded sha256-hash of this string
# into the DNS TXT record.
sub key_authorization {
    my ($self, $token) = @_;
    return $token .'.'. $self->jwk_thumbprint();
}

# JWS signing using the RS256 alg (RSA/SHA256).
sub jws {
    my ($self, $use_jwk, $data, $url) = @_;
    my $key = $self->{key}
	or die "No key was generated yet\n";

    my $payload = encode(tojs($data));

    if (!defined($self->{nonce})) {
	my $method = $self->_method('newNonce');
	$self->do(GET => $method);
    }

    # The acme protocol requires the actual request URL be in the protected
    # header. There is no unprotected header.
    my $protected = {
	alg => 'RS256',
	url => $url,
	nonce => $self->{nonce} // die "missing nonce\n"
    };

    # header contains either
    # - kid, reference to account URL
    # - jwk, key itself
    # the latter is only allowed for
    # - creating accounts (no account URL yet)
    # - revoking certificates with the certificate key instead of account key
    if ($use_jwk) {
	$protected->{jwk} = $self->jwk();
    } else {
	$protected->{kid} = $self->{location};
    }

    $protected = encode(tojs($protected));

    my $signdata = "$protected.$payload";
    my $signature = encode($key->sign($signdata));

    return {
	protected => $protected,
	payload => $payload,
	signature => $signature,
    };
}

sub __get_result {
    my ($resp, $code, $plain) = @_;

    die "expected code '$code', received '".$resp->code."'\n"
	if $resp->code != $code;

    return $plain ? $resp->decoded_content : fromjs($resp->decoded_content);
}

# Get the list of method URLs and query the directory if we have to.
sub __get_methods {
    my ($self) = @_;
    if (my $methods = $self->{methods}) {
	return $methods;
    }
    my $r = $self->do(GET => $self->{directory});
    my $methods = __get_result($r, 200);
    $self->fatal("unable to decode methods returned by directory - $@", $r) if $@;
    return ($self->{methods} = $methods);
}

# Get a method, causing the directory to be queried first if necessary.
sub _method {
    my ($self, $method) = @_;
    my $methods = $self->__get_methods();
    my $url = $methods->{$method}
	or die "no such method: $method\n";
    return $url;
}

# Get $self->{account} with an error if we don't have one yet.
sub _account {
    my ($self) = @_;
    my $account = $self->{account}
	// die "no account loaded\n";
    return wantarray ? ($account, $self->{location}) : $account;
}

# debugging info
sub list_methods {
    my ($self) = @_;
    my $methods = $self->__get_methods();
    if (my $meta = $methods->{meta}) {
	print("(meta): $_ : $meta->{$_}\n") for sort keys %$meta;
    }
    print("$_ : $methods->{$_}\n") for sort grep {$_ ne 'meta'} keys %$methods;
}

# return (optional) meta directory entry.
# this is public because it might contain the ToS, which should be displayed
# and agreed to before creating an account
sub get_meta {
    my ($self) = @_;
    my $methods = $self->__get_methods();
    return $methods->{meta};
}

# Common code between new_account and update_account
sub __new_account {
    my ($self, $expected_code, $url, $new, %info) = @_;
    my $req = {
	%info,
    };
    my $r = $self->do(POST => $url, $req, $new);
    eval {
	my $account = __get_result($r, $expected_code);
	if (!defined($self->{location})) {
	    my $account_url = $r->header('Location')
		or die "did not receive an account URL\n";
	    $self->{location} = $account_url;
	}
	$self->{account} = $account;
	$self->save();
    };
    $self->fatal("POST to '$url' failed - $@", $r) if $@;
    return $self->{account};
}

# Create a new account using data in %info.
# Optionally pass $tos_url to agree to the given Terms of Service
# POST to newAccount endpoint
# Expects a '201 Created' reply
# Saves and returns the account data
sub new_account {
    my ($self, $tos_url, %info) = @_;
    my $url = $self->_method('newAccount');

    if ($tos_url) {
	$self->{tos} = $tos_url;
	$info{termsOfServiceAgreed} = JSON::true;
    }

    return $self->__new_account(201, $url, 1, %info);
}

# Update existing account with new %info
# POST to account URL
# Expects a '200 OK' reply
# Saves and returns updated account data
sub update_account {
    my ($self, %info) = @_;
    my (undef, $url) = $self->_account;

    return $self->__new_account(200, $url, 0, %info);
}

# Retrieves existing account information
# POST to account URL with empty body!
# Expects a '200 OK' reply
# Saves and returns updated account data
sub get_account {
    my ($self) = @_;
    return $self->update_account();
}

# Start a new order for one or more domains
# POST to newOrder endpoint
# Expects a '201 Created' reply
# returns order URL and parsed order object, including authorization and finalize URLs
sub new_order {
    my ($self, $domains) = @_;

    my $url = $self->_method('newOrder');
    my $req = {
	identifiers => [ map { { type => 'dns', value => $_ } } @$domains ],
    };

    my $r = $self->do(POST => $url, $req);
    my ($order_url, $order);
    eval {
	$order_url = $r->header('Location')
	    or die "did not receive an order URL\n";
	$order = __get_result($r, 201)
    };
    $self->fatal("POST to '$url' failed - $@", $r) if $@;
    return ($order_url, $order);
}

# Finalize order after all challenges have been validated
# POST to order's finalize URL
# Expects a '200 OK' reply
# returns (potentially updated) order object
sub finalize_order {
    my ($self, $order, $csr) = @_;

    my $req = {
	csr => encode($csr),
    };
    my $r = $self->do(POST => $order->{finalize}, $req);
    my $return = eval { __get_result($r, 200); };
    $self->fatal("POST to '$order->{finalize}' failed - $@", $r) if $@;
    return $return;
}

# Get order status
# GET to order URL
# Expects a '200 OK' reply
# returns order object
sub get_order {
    my ($self, $order_url) = @_;
    my $r = $self->do(GET => $order_url);
    my $return = eval { __get_result($r, 200); };
    $self->fatal("GET of '$order_url' failed - $@", $r) if $@;
    return $return;
}

# Gets authorization object
# GET to authorization URL
# Expects a '200 OK' reply
# returns authorization object, including challenges array
sub get_authorization {
    my ($self, $auth_url) = @_;

    my $r = $self->do(GET => $auth_url);
    my $return = eval { __get_result($r, 200); };
    $self->fatal("GET of '$auth_url' failed - $@", $r) if $@;
    return $return;
}

# Deactivates existing authorization
# POST to authorization URL
# Expects a '200 OK' reply
# returns updated authorization object
sub deactivate_authorization {
    my ($self, $auth_url) = @_;

    my $req = {
	status => 'deactivated',
    };
    my $r = $self->do(POST => $auth_url, $req);
    my $return = eval { __get_result($r, 200); };
    $self->fatal("POST to '$auth_url' failed - $@", $r) if $@;
    return $return;
}

# Get certificate
# GET to order's certificate URL
# Expects a '200 OK' reply
# returns certificate chain in PEM format
sub get_certificate {
    my ($self, $order) = @_;

    $self->fatal("no certificate URL available (yet?)", $order)
       if !$order->{certificate};

    my $r = $self->do(GET => $order->{certificate});
    my $return = eval { __get_result($r, 200, 1); };
    $self->fatal("GET of '$order->{certificate}' failed - $@", $r) if $@;
    return $return;
}

# Revoke given certificate
# POST to revokeCert endpoint
# currently only supports revokation with account key
# $certificate can either be PEM or DER encoded
# Expects a '200 OK' reply
sub revoke_certificate {
    my ($self, $certificate, $reason) = @_;

    my $url = $self->_method('revokeCert');

    if ($certificate =~ /^-----BEGIN CERTIFICATE-----/) {
	$certificate = PVE::Certificate::pem_to_der($certificate);
    }

    my $req = {
	certificate => encode($certificate),
	reason => $reason // 0,
    };
    # TODO: set use_jwk if revoking with certificate key
    my $r = $self->do(POST => $url, $req);
    eval {
	die "unexpected code $r->code\n" if $r->code != 200;
    };
    $self->fatal("POST to '$url' failed - $@", $r) if $@;
}

# Request validation of challenge
# POST to challenge URL
# call after validation has been setup
# returns (potentially updated) challenge object
sub request_challenge_validation {
    my ($self, $url, $key_authorization) = @_;

    my $req = { keyAuthorization => $key_authorization };

    my $r = $self->do(POST => $url, $req);
    my $return = eval { __get_result($r, 200); };
    $self->fatal("POST to '$url' failed - $@", $r) if $@;
    return $return;
}

# actually 'do' a $method request on $url
# $data: input for JWS, optional
# $use_jwk: use JWK instead of KID in JWD (see sub jws)
sub do {
    my ($self, $method, $url, $data, $use_jwk) = @_;

    $self->fatal("Error: can't $method to empty URL") if !$url || $url eq '';

    my $headers = HTTP::Headers->new();
    $headers->header('Content-Type' => 'application/jose+json');
    my $content = defined($data) ? $self->jws($use_jwk, $data, $url) : undef;
    my $request;
    if (defined($content)) {
	$content = tojs($content);
	$request = HTTP::Request->new($method, $url, $headers, $content);
    } else {
	$request = HTTP::Request->new($method, $url, $headers);
    }
    my $res = $self->{ua}->request($request);
    if (!$res->is_success) {
	# check for nonce rejection
	if ($res->code == 400 && $res->decoded_content) {
	    my $parsed_content = fromjs($res->decoded_content);
	    if ($parsed_content->{type} eq 'urn:ietf:params:acme:error:badNonce') {
		warn("bad Nonce, retrying\n");
		$self->{nonce} = $res->header('Replay-Nonce');
		return $self->do($method, $url, $data, $use_jwk);
	    }
	}
	$self->fatal("Error: $method to $url\n".$res->decoded_content, $res);
    }
    if (my $nonce = $res->header('Replay-Nonce')) {
	$self->{nonce} = $nonce;
    }
    return $res;
}

1;
