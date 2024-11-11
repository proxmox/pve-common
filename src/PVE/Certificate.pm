package PVE::Certificate;

use strict;
use warnings;

use Date::Parse;
use Encode qw(decode encode);
use MIME::Base64 qw(decode_base64 encode_base64);
use Net::SSLeay;

use PVE::JSONSchema qw(get_standard_option);

Net::SSLeay::load_error_strings();
Net::SSLeay::randomize();

PVE::JSONSchema::register_format('pem-certificate', sub {
    my ($content, $noerr) = @_;

    return check_pem($content, noerr => $noerr);
});

PVE::JSONSchema::register_format('pem-certificate-chain', sub {
    my ($content, $noerr) = @_;

    return check_pem($content, noerr => $noerr, multiple => 1);
});

PVE::JSONSchema::register_format('pem-string', sub {
    my ($content, $noerr) = @_;

    return check_pem($content, noerr => $noerr, label => qr/.*?/);
});

PVE::JSONSchema::register_standard_option('pve-certificate-info', {
    type => 'object',
    properties => {
	filename => {
	    type => 'string',
	    optional => 1,
	},
	fingerprint => get_standard_option('fingerprint-sha256', {
	    optional => 1,
	}),
	subject => {
	    type => 'string',
	    description => 'Certificate subject name.',
	    optional => 1,
	},
	issuer => {
	    type => 'string',
	    description => 'Certificate issuer name.',
	    optional => 1,
	},
	notbefore => {
	    type => 'integer',
	    description => 'Certificate\'s notBefore timestamp (UNIX epoch).',
	    renderer => 'timestamp',
	    optional => 1,
	},
	notafter => {
	    type => 'integer',
	    description => 'Certificate\'s notAfter timestamp (UNIX epoch).',
	    renderer => 'timestamp',
	    optional => 1,
	},
	san => {
	    type => 'array',
	    description => 'List of Certificate\'s SubjectAlternativeName entries.',
	    optional => 1,
	    renderer => 'yaml',
	    items => {
		type => 'string',
	    },
	},
	pem => {
	    type => 'string',
	    description => 'Certificate in PEM format',
	    format => 'pem-certificate',
	    optional => 1,
	},
	'public-key-type' => {
	    type => 'string',
	    description => 'Certificate\'s public key algorithm',
	    optional => 1,
	},
	'public-key-bits' => {
	    type => 'integer',
	    description => 'Certificate\'s public key size',
	    optional => 1,
	},
    },
});

my $header_re = sub {
    my ($label) = @_;
    return qr!-----BEGIN\ $label-----(?:\s|\n)*!;
};
my $footer_re = sub {
    my ($label) = @_;
    return qr!-----END\ $label-----(?:\s|\n)*!;
};
my $pem_re = sub {
    my ($label) = @_;

    my $b64_char_re = qr![0-9A-Za-z\+/]!; # see RFC 7468
    my $header = $header_re->($label);
    my $footer = $footer_re->($label);

    return qr{
	$header
	(?:(?:$b64_char_re)+\s*\n)*
	(?:$b64_char_re)*(?:=\s*\n=|={0,2})?\s*\n
	$footer
    }x;
};

sub strip_leading_text {
    my ($content) = @_;

    my $header = $header_re->(qr/.*?/);
    $content =~ s/^.*?(?=$header)//s;
    return $content;
};

sub split_pem {
    my ($content, %opts) = @_;
    my $label = $opts{label} // 'CERTIFICATE';

    my $header = $header_re->($label);
    return split(/(?=$header)/,$content);
}

sub check_pem {
    my ($content, %opts) = @_;

    $content = strip_leading_text($content);

    my $re = $pem_re->($opts{label} // 'CERTIFICATE');
    $re = qr/($re\n+)*$re/ if $opts{multiple};

    return $content if $content =~ /^$re$/; # OK

    return undef if $opts{noerr};
    die "not a valid PEM-formatted string.\n";
}

sub pem_to_der {
    my ($content) = @_;

    my $header = $header_re->(qr/.*?/);
    my $footer = $footer_re->(qr/.*?/);

    $content = strip_leading_text($content);

    # only take first PEM entry
    $content =~ s/^$header$//mg;
    $content =~ s/$footer.*//sg;

    $content = decode_base64($content);

    return $content;
}

sub der_to_pem {
    my ($content, %opts) = @_;

    my $label = $opts{label} // 'CERTIFICATE';

    my $b64 = encode_base64($content, '');
    $b64 = join("\n", ($b64 =~ /.{1,64}/sg));
    return "-----BEGIN $label-----\n$b64\n-----END $label-----\n";
}

my sub ssl_die {
    my ($msg) = @_;
    warn Net::SSLeay::print_errs();
    Net::SSLeay::die_now("$msg\n");
};

my $read_certificate = sub {
    my ($cert_path) = @_;

    die "'$cert_path' does not exist!\n" if ! -e $cert_path;

    my $bio = Net::SSLeay::BIO_new_file($cert_path, 'r')
	or ssl_die("unable to read '$cert_path' - $!");

    my $cert = Net::SSLeay::PEM_read_bio_X509($bio);
    Net::SSLeay::BIO_free($bio);
    die "unable to read certificate from '$cert_path'\n" if !$cert;

    return $cert;
};

sub convert_asn1_to_epoch {
    my ($asn1_time) = @_;

    ssl_die("invalid ASN1 time object") if !$asn1_time;
    my $iso_time = Net::SSLeay::P_ASN1_TIME_get_isotime($asn1_time);
    ssl_die("unable to parse ASN1 time") if $iso_time eq '';
    return Date::Parse::str2time($iso_time);
}

sub get_certificate_fingerprint {
    my ($cert_path) = @_;

    my $cert = $read_certificate->($cert_path);

    my $fp = Net::SSLeay::X509_get_fingerprint($cert, 'sha256');
    Net::SSLeay::X509_free($cert);

    die "unable to get fingerprint for '$cert_path' - got empty value\n"
	if !defined($fp) || $fp eq '';

    return $fp;
}

sub assert_certificate_matches_key {
    my ($cert_path, $key_path) = @_;

    die "No certificate path given!\n" if !$cert_path;
    die "No certificate key path given!\n" if !$key_path;

    die "Certificate at '$cert_path' does not exist!\n" if ! -e $cert_path;
    die "Certificate key '$key_path' does not exist!\n" if ! -e $key_path;

    my $ctx = Net::SSLeay::CTX_new()
	or ssl_die("Failed to create SSL context in order to verify private key");

    eval {
	my $filetype = &Net::SSLeay::FILETYPE_PEM;

	Net::SSLeay::CTX_use_PrivateKey_file($ctx, $key_path, $filetype)
	    or ssl_die("Failed to load private key from '$key_path' into SSL context");

	Net::SSLeay::CTX_use_certificate_file($ctx, $cert_path, $filetype)
	    or ssl_die("Failed to load certificate from '$cert_path' into SSL context");

	Net::SSLeay::CTX_check_private_key($ctx)
	    or ssl_die("Failed to validate private key and certificate");
    };
    my $err = $@;

    Net::SSLeay::CTX_free($ctx);

    die $err if $err;

    return 1;
}

sub get_certificate_info {
    my ($cert_path) = @_;

    my $cert = $read_certificate->($cert_path);

    my $parse_san = sub {
	my $res = [];
	while (my ($type, $value) = splice(@_, 0, 2)) {
	    if ($type != 2 && $type != 7) {
		warn "unexpected SAN type encountered: $type\n";
		next;
	    }

	    if ($type == 7) {
		my $hex = unpack("H*", $value);
		if (length($hex) == 8) {
		    # IPv4
		    $value = join(".", unpack("C4C4C4C4", $value));
		} elsif (length($hex) == 32) {
		    # IPv6
		    $value = join(":", unpack("H4H4H4H4H4H4H4H4", $value));
		} else {
		    warn "cannot parse SAN IP entry '0x${hex}'\n";
		    next;
		}
	    }

	    push @$res, $value;
	}
	return $res;
    };

    my $info = {};

    $info->{fingerprint} = Net::SSLeay::X509_get_fingerprint($cert, 'sha256');

    if (my $subject = Net::SSLeay::X509_get_subject_name($cert)) {
	$info->{subject} = Net::SSLeay::X509_NAME_oneline($subject);
    }

    if (my $issuer = Net::SSLeay::X509_get_issuer_name($cert)) {
	$info->{issuer} = Net::SSLeay::X509_NAME_oneline($issuer);
    }

    eval { $info->{notbefore} = convert_asn1_to_epoch(Net::SSLeay::X509_get_notBefore($cert)) };
    warn $@ if $@;
    eval { $info->{notafter} = convert_asn1_to_epoch(Net::SSLeay::X509_get_notAfter($cert)) };
    warn $@ if $@;

    $info->{san} = $parse_san->(Net::SSLeay::X509_get_subjectAltNames($cert));
    $info->{pem} = Net::SSLeay::PEM_get_string_X509($cert);

    my $pub_key = eval { Net::SSLeay::X509_get_pubkey($cert) };
    warn $@ if $@;
    if ($pub_key) {
	$info->{'public-key-type'} = Net::SSLeay::OBJ_nid2sn(Net::SSLeay::EVP_PKEY_id($pub_key));
	$info->{'public-key-bits'} = Net::SSLeay::EVP_PKEY_bits($pub_key);
	Net::SSLeay::EVP_PKEY_free($pub_key);
    }

    Net::SSLeay::X509_free($cert);

    $cert_path =~ s!^.*/!!g;
    $info->{filename} = $cert_path;

    return $info;
};

# Obtain the expiration timestamp of a X.509 certificate as a UNIX epoch.
sub get_expiration_as_epoch {
    my ($cert_path) = @_;

    my $cert = $read_certificate->($cert_path);
    my $not_after = eval { convert_asn1_to_epoch(Net::SSLeay::X509_get_notAfter($cert)) };
    my $err = $@;

    Net::SSLeay::X509_free($cert);

    die $err if $err;

    return $not_after;
};

# Checks whether certificate expires before $timestamp (UNIX epoch)
sub check_expiry {
    my ($cert_path, $timestamp) = @_;

    $timestamp //= time();

    my $not_after = get_expiration_as_epoch($cert_path);

    return ($not_after < $timestamp) ? 1 : 0;
};

# Create a CSR and certificate key for a given order
# returns path to CSR file or path to CSR and key files
sub generate_csr {
    my (%attr) = @_;

    # optional
    my $bits = delete($attr{bits}) // 4096;
    my $dig_alg = delete($attr{digest}) // 'sha256';
    my $pem_key = delete($attr{private_key});

    # required
    my $identifiers = delete($attr{identifiers});

    die "Identifiers are required to generate a CSR.\n"
	if !defined($identifiers);

    my $san = [ map { $_->{value} } grep { $_->{type} eq 'dns' } @$identifiers ];
    die "DNS identifiers are required to generate a CSR.\n" if !scalar @$san;

    # optional
    my $common_name = delete($attr{common_name}) // $san->[0];

    my $md = eval { Net::SSLeay::EVP_get_digestbyname($dig_alg) };
    die "Invalid digest algorithm '$dig_alg'\n" if !$md;

    my ($bio, $pk, $req);

    my $cleanup = sub {
	my ($die_msg, $no_warn) = @_;
	Net::SSLeay::print_errs() if !$no_warn;

	Net::SSLeay::X509_REQ_free($req) if  $req;
	Net::SSLeay::EVP_PKEY_free($pk) if $pk;
	Net::SSLeay::BIO_free($bio) if $bio;

	die $die_msg if $die_msg;
    };

    # this unfortunately causes a small memory leak, since there is no
    # X509_NAME_free() (yet)
    my $name = Net::SSLeay::X509_NAME_new();
    ssl_die("Failed to allocate X509_NAME object") if !$name;
    my $add_name_entry = sub {
	my ($k, $v) = @_;

	my $res = Net::SSLeay::X509_NAME_add_entry_by_txt(
	    $name, $k, &Net::SSLeay::MBSTRING_UTF8, encode('utf-8', $v));

	$cleanup->("Failed to add '$k'='$v' to DN\n") if !$res;
    };

    $add_name_entry->('CN', $common_name);
    for (qw(C ST L O OU)) {
	if (defined(my $v = $attr{$_})) {
	    $add_name_entry->($_, $v);
	}
    }

    if (defined($pem_key)) {
	my $bio_s_mem = Net::SSLeay::BIO_s_mem();
	$cleanup->("Failed to allocate BIO_s_mem for private key\n") if !$bio_s_mem;

	$bio = Net::SSLeay::BIO_new($bio_s_mem);
	$cleanup->("Failed to allocate BIO for private key\n") if !$bio;

	$cleanup->("Failed to write PEM-encoded key to BIO\n")
	    if Net::SSLeay::BIO_write($bio, $pem_key) <= 0;

	$pk = Net::SSLeay::PEM_read_bio_PrivateKey($bio);
	$cleanup->("Failed to read private key into EVP_PKEY\n") if !$pk;
    } else {
	$pk = Net::SSLeay::EVP_PKEY_new();
	$cleanup->("Failed to allocate EVP_PKEY for private key\n") if !$pk;

	my $rsa = Net::SSLeay::RSA_generate_key($bits, 65537);
	$cleanup->("Failed to generate RSA key pair\n") if !$rsa;

	$cleanup->("Failed to assign RSA key to EVP_PKEY\n")
	    if !Net::SSLeay::EVP_PKEY_assign_RSA($pk, $rsa);
    }

    $req = Net::SSLeay::X509_REQ_new();
    $cleanup->("Failed to allocate X509_REQ\n") if !$req;

    $cleanup->("Failed to set subject name\n")
	if (!Net::SSLeay::X509_REQ_set_subject_name($req, $name));

    Net::SSLeay::P_X509_REQ_add_extensions(
	$req,
	&Net::SSLeay::NID_key_usage => 'digitalSignature,keyEncipherment',
	&Net::SSLeay::NID_basic_constraints => 'CA:FALSE',
	&Net::SSLeay::NID_ext_key_usage => 'serverAuth,clientAuth',
	&Net::SSLeay::NID_subject_alt_name => join(',', map { "DNS:$_" } @$san),
    ) or $cleanup->("Failed to add extensions to CSR\n");

    $cleanup->("Failed to set public key\n") if !Net::SSLeay::X509_REQ_set_pubkey($req, $pk);

    $cleanup->("Failed to set CSR version\n") if !Net::SSLeay::X509_REQ_set_version($req, 0);

    $cleanup->("Failed to sign CSR\n") if !Net::SSLeay::X509_REQ_sign($req, $pk, $md);

    my $pk_pem = Net::SSLeay::PEM_get_string_PrivateKey($pk);
    my $req_pem = Net::SSLeay::PEM_get_string_X509_REQ($req);

    $cleanup->(undef, 1);

    return wantarray ? ($req_pem, $pk_pem) : $req_pem;
}

1;
