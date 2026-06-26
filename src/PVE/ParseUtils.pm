package PVE::ParseUtils;

# Small, dependency-free helpers and patterns for handling the textual form of
# values: list splitting, text encoding, and IP/email matching. Kept low-level
# so both PVE::Tools and PVE::JSONSchema can use them without pulling in more.

use v5.36;

use Encode;
use URI::Escape;

use base 'Exporter';

our @EXPORT_OK = qw(
    split_list
    encode_text
    decode_text
    $IPV4RE
    $IPV6RE
    $IPRE
    $EMAIL_RE
    $EMAIL_USER_RE
);

my $IPV4OCTET = "(?:25[0-5]|(?:2[0-4]|1[0-9]|[1-9])?[0-9])";
our $IPV4RE = "(?:(?:$IPV4OCTET\\.){3}$IPV4OCTET)";
my $IPV6H16 = "(?:[0-9a-fA-F]{1,4})";
my $IPV6LS32 = "(?:(?:$IPV4RE|$IPV6H16:$IPV6H16))";

#<<< The Regex is formatted as it is by design to improve readability.
our $IPV6RE = "(?:" .
    "(?:(?:" .                               "(?:$IPV6H16:){6})$IPV6LS32)|"
    . "(?:(?:" .                           "::(?:$IPV6H16:){5})$IPV6LS32)|"
    . "(?:(?:(?:" .              "$IPV6H16)?::(?:$IPV6H16:){4})$IPV6LS32)|"
    . "(?:(?:(?:(?:$IPV6H16:){0,1}$IPV6H16)?::(?:$IPV6H16:){3})$IPV6LS32)|"
    . "(?:(?:(?:(?:$IPV6H16:){0,2}$IPV6H16)?::(?:$IPV6H16:){2})$IPV6LS32)|"
    . "(?:(?:(?:(?:$IPV6H16:){0,3}$IPV6H16)?::(?:$IPV6H16:){1})$IPV6LS32)|"
    . "(?:(?:(?:(?:$IPV6H16:){0,4}$IPV6H16)?::" .           ")$IPV6LS32)|"
    . "(?:(?:(?:(?:$IPV6H16:){0,5}$IPV6H16)?::" .            ")$IPV6H16)|"
    . "(?:(?:(?:(?:$IPV6H16:){0,6}$IPV6H16)?::" .                    ")))"
    ;
#>>>

our $IPRE = "(?:$IPV4RE|$IPV6RE)";

our $EMAIL_USER_RE = qr/[\w\+\-\~]+(\.[\w\+\-\~]+)*/;
our $EMAIL_RE = qr/$EMAIL_USER_RE@[a-zA-Z0-9\-]+(\.[a-zA-Z0-9\-]+)*/;

sub split_list($listtxt = '') {
    $listtxt //= ''; # tolerate an explicitly passed undef

    return split(/\0/, $listtxt) if $listtxt =~ m/\0/;

    $listtxt =~ s/[,;]/ /g;
    $listtxt =~ s/^\s+//;

    return split(/\s+/, $listtxt);
}

sub encode_text($text) {
    # all control and hi-bit characters, ':' and '%'
    my $unsafe = "^\x20-\x24\x26-\x39\x3b-\x7e";
    return uri_escape(Encode::encode("utf8", $text), $unsafe);
}

sub decode_text($data) {
    return Encode::decode("utf8", uri_unescape($data));
}

1;
