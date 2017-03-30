package PVE::OTP;

use strict;
use warnings;
use Digest::SHA;
use MIME::Base32; #libmime-base32-perl
use MIME::Base64;
use URI::Escape;
use HTTP::Request;
use LWP::UserAgent;

use PVE::Tools;

# hotp/totp code

sub hotp($$;$) {
	my ($binsecret, $number, $digits) = @_;

	$digits = 6 if !defined($digits);

	my $bincounter = pack('Q>', $number);
	my $hmac = Digest::SHA::hmac_sha1($bincounter, $binsecret);

	my $offset = unpack('C', substr($hmac,19) & pack('C', 0x0F));
	my $part = substr($hmac, $offset, 4);
	my $otp = unpack('N', $part);
	my $value = ($otp & 0x7fffffff) % (10**$digits);
	return sprintf("%0${digits}d", $value);
}

# experimental code for yubico OTP verification

sub yubico_compute_param_sig {
    my ($param, $api_key) = @_;

    my $paramstr = '';
    foreach my $key (sort keys %$param) {
	$paramstr .= '&' if $paramstr;
	$paramstr .= "$key=$param->{$key}";
    }

    # hmac_sha1_base64 does not add '=' padding characters, so we use encode_base64
    my $sig = uri_escape(encode_base64(Digest::SHA::hmac_sha1($paramstr, decode_base64($api_key || '')), ''));

    return ($paramstr, $sig);
}

sub yubico_verify_otp {
    my ($otp, $keys, $url, $api_id, $api_key, $proxy) = @_;

    die "yubico: missing password\n" if !defined($otp);
    die "yubico: missing API ID\n" if !defined($api_id);
    die "yubico: missing API KEY\n" if !defined($api_key);
    die "yubico: no associated yubico keys\n" if $keys =~ m/^\s+$/;

    die "yubico: wrong OTP length\n" if (length($otp) < 32) || (length($otp) > 48);

    $url = 'http://api2.yubico.com/wsapi/2.0/verify' if !defined($url);

    my $params = {
	nonce =>  Digest::SHA::hmac_sha1_hex(time(), rand()),
	id => $api_id,
	otp => uri_escape($otp),
	timestamp => 1,
    };

    my ($paramstr, $sig) = yubico_compute_param_sig($params, $api_key);

    $paramstr .= "&h=$sig" if $api_key;

    my $req = HTTP::Request->new('GET' => "$url?$paramstr");

    my $ua = LWP::UserAgent->new(protocols_allowed => ['http', 'https'], timeout => 30);

    if ($proxy) {
	$ua->proxy(['http', 'https'], $proxy);
    } else {
	$ua->env_proxy;
    }

    my $response = $ua->request($req);
    my $code = $response->code;

    if ($code != 200) {
	my $msg = $response->message || 'unknown';
	die "Invalid response from server: $code $msg\n";
    }

    my $raw = $response->decoded_content;

    my $result = {};
    foreach my $kvpair (split(/\n/, $raw)) {
	chomp $kvpair;
	if($kvpair =~ /^\S+=/) {
	    my ($k, $v) = split(/=/, $kvpair, 2);
	    $v =~ s/\s//g;
	    $result->{$k} = $v;
        }
    }

    my $rsig = $result->{h};
    delete $result->{h};

    if ($api_key) {
	my ($datastr, $vsig) = yubico_compute_param_sig($result, $api_key);
	$vsig = uri_unescape($vsig);
	die "yubico: result signature verification failed\n" if $rsig ne $vsig;
    }

    die "yubico auth failed: $result->{status}\n" if $result->{status} ne 'OK';

    my $publicid = $result->{publicid} = substr(lc($result->{otp}), 0, 12);

    my $found;
    foreach my $k (PVE::Tools::split_list($keys)) {
	if ($k eq $publicid) {
	    $found = 1;
	    last;
	}
    }

    die "yubico auth failed: key does not belong to user\n" if !$found;

    return $result;
}

sub oath_verify_otp {
    my ($otp, $keys, $step, $digits) = @_;

    die "oath: missing password\n" if !defined($otp);
    die "oath: no associated oath keys\n" if $keys =~ m/^\s+$/;

    $step = 30 if !$step;
    $digits = 6 if !$digits;

    my $found;
    foreach my $k (PVE::Tools::split_list($keys)) {
	# Note: we generate 3 values to allow small time drift
	my $binkey;
	if ($k =~ /^[A-Z2-7=]{16}$/) {
	    $binkey = MIME::Base32::decode_rfc3548($k);
	} elsif ($k =~ /^[A-Fa-f0-9]{40}$/) {
	    $binkey = pack('H*', $k);
	} else {
	    die "unrecognized key format, must be hex or base32 encoded\n";
	}

	# force integer division for time/step
	use integer;
	my $now = time()/$step - 1;
	$found = 1 if $otp eq hotp($binkey, $now+0, $digits);
	$found = 1 if $otp eq hotp($binkey, $now+1, $digits);
	$found = 1 if $otp eq hotp($binkey, $now+2, $digits);
	last if $found;
    }

    die "oath auth failed\n" if !$found;
}

1;
