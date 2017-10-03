package PVE::Subscription;

use strict;
use warnings;
use Digest::MD5 qw(md5_hex md5_base64);
use MIME::Base64;
use HTTP::Request;
use URI;
use LWP::UserAgent;
use JSON;

use PVE::Tools;
use PVE::INotify;

# How long the local key is valid for in between remote checks
our $localkeydays = 15;
# How many days to allow after local key expiry before blocking
# access if connection cannot be made
my $allowcheckfaildays = 5;

my $shared_key_data = "kjfdlskfhiuewhfk947368";

my $saved_fields = {
    key => 1,
    checktime => 1,
    status => 1,
    message => 0,
    validdirectory => 1,
    productname => 1,
    regdate => 1,
    nextduedate => 1,
};

sub check_fields {
    my ($info, $server_id) = @_;

    foreach my $f (qw(status checktime key)) {
	if (!$info->{$f}) {
	    die "Missing field '$f'\n";
	}
    }

    if ($info->{checktime} > time()) {
	die "Last check time in future.\n";
    }

    return undef if $info->{status} ne 'Active';

    foreach my $f (keys %$saved_fields) {
	next if !$saved_fields->{$f};
	if (!$info->{$f}) {
	    die "Missing field '$f'\n";
	}
    }

    my $found;
    foreach my $hwid (split(/,/, $info->{validdirectory})) {
	if ($hwid eq $server_id) {
	    $found = 1;
	    last;
	}
    }
    die "Server ID does not match\n" if !$found;

    return undef;
}

sub check_subscription {
    my ($key, $server_id, $proxy) = @_;

    my $whmcsurl = "https://shop.maurer-it.com";

    my $uri = "$whmcsurl/modules/servers/licensing/verify.php";

    my $check_token = time() . md5_hex(rand(8999999999) + 1000000000) . $key;

    my $params = {
	licensekey => $key,
	dir => $server_id,
	domain => 'www.proxmox.com',
	ip => 'localhost',
	check_token => $check_token,
    };

    my $req = HTTP::Request->new('POST' => $uri);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    # We use a temporary URI object to format
    # the application/x-www-form-urlencoded content.
    my $url = URI->new('http:');
    $url->query_form(%$params);
    my $content = $url->query;
    $req->header('Content-Length' => length($content));
    $req->content($content);

    my $ua = LWP::UserAgent->new(protocols_allowed => ['https'], timeout => 30);

    if ($proxy) {
	$ua->proxy(['https'], $proxy);
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

    my $subinfo = {};
    while ($raw =~ m/<(.*?)>([^<]+)<\/\1>/g) {
	my ($k, $v) = ($1, $2);
	next if !($k eq 'md5hash' || defined($saved_fields->{$k}));
	$subinfo->{$k} = $v;
    }
    $subinfo->{checktime} = time();
    $subinfo->{key} = $key;

    if ($subinfo->{message}) {
	$subinfo->{message} =~ s/^Directory Invalid$/Invalid Server ID/;
    }

    my $emd5sum = md5_hex($shared_key_data . $check_token);
    if ($subinfo->{status} && $subinfo->{status} eq 'Active') {
	if (!$subinfo->{md5hash} || ($subinfo->{md5hash} ne $emd5sum)) {
	    die "MD5 Checksum Verification Failed\n";
	}
    }

    delete $subinfo->{md5hash};

    check_fields($subinfo, $server_id);

    return $subinfo;
}

sub read_subscription {
    my ($server_id, $filename, $fh) = @_;

    my $info = { status => 'Invalid' };

    my $key = <$fh>; # first line is the key
    chomp $key;

    $info->{key} = $key;

    my $csum = <$fh>; # second line is a checksum

    my $data = '';
    while (defined(my $line = <$fh>)) {
	$data .= $line;
    }

    if ($key && $csum && $data) {

	chomp $csum;

	my $localinfo = {};

	eval {
	    my $json_text = decode_base64($data);
	    $localinfo = decode_json($json_text);
	    my $newcsum = md5_base64($localinfo->{checktime} . $data . $shared_key_data);
	    die "checksum failure\n" if $csum ne $newcsum;

	    check_fields($localinfo, $server_id);

	    my $age = time() -  $localinfo->{checktime};

	    my $maxage = ($localkeydays + $allowcheckfaildays)*60*60*24;
	    die "subscription info too old\n"
		if ($localinfo->{status} eq 'Active') && ($age > $maxage);
	};
	if (my $err = $@) {
	    chomp $err;
	    $info->{message} = $err;
	} else {
	    $info = $localinfo;
	}
    }

    return $info;
}

sub update_apt_auth {
    my ($key, $server_id) = @_;

    my $auth = { 'enterprise.proxmox.com' => { login => $key, password => $server_id } };
    PVE::INotify::update_file('apt-auth', $auth);
}

sub write_subscription {
    my ($server_id, $filename, $fh, $info) = @_;

    if ($info->{status} eq 'New') {
	PVE::Tools::safe_print($filename, $fh, "$info->{key}\n");
    } else {
	my $json = encode_json($info);
	my $data = encode_base64($json);
	my $csum = md5_base64($info->{checktime} . $data . $shared_key_data);

	my $raw = "$info->{key}\n$csum\n$data";

	PVE::Tools::safe_print($filename, $fh, $raw);
    }

    update_apt_auth($info->{key}, $server_id);
}

1;
