package PVE::LDAP;

use strict;
use warnings;

use Net::IP;
use Net::LDAP;
use Net::LDAP::Control::Paged;
use Net::LDAP::Constant qw(LDAP_CONTROL_PAGED);

sub ldap_connect {
    my ($servers, $scheme, $port, $opts) = @_;

    my $start_tls = 0;

    if ($scheme eq 'ldap+starttls') {
	$scheme = 'ldap';
	$start_tls = 1;
    }

    my %ldap_opts = (
	scheme => $scheme,
	port => $port,
	timeout => 10,
	onerror => 'die',
    );

    my $hosts = [];
    for my $host (@$servers) {
	if (Net::IP::ip_is_ipv6($host)) {
	    push @$hosts, "[$host]";
	} else {
	    push @$hosts, $host;
	}
    }

    for my $opt (qw(clientcert clientkey capath cafile sslversion verify)) {
	$ldap_opts{$opt} = $opts->{$opt} if $opts->{$opt};
    }

    my $ldap = Net::LDAP->new($hosts, %ldap_opts) || die "$@\n";

    if ($start_tls) {
	$ldap->start_tls(%$opts);
    }

    return $ldap;
}

sub ldap_bind {
    my ($ldap, $dn, $pw) = @_;

    my $res;
    if (defined($dn) && defined($pw)) {
	$res = $ldap->bind($dn, password => $pw);
    } else { # anonymous bind
	$res = $ldap->bind();
    }

    my $code = $res->code;
    my $err = $res->error;

    die "ldap bind failed: $err\n" if $code;
}

sub get_user_dn {
    my ($ldap, $name, $attr, $base_dn) = @_;

    # search for dn
    my $result = $ldap->search(
	base    => $base_dn // "",
	scope   => "sub",
	filter  => "$attr=$name",
	attrs   => ['dn']
    );
    return undef if !$result->entries;
    my @entries = $result->entries;
    return $entries[0]->dn;
}

sub auth_user_dn {
    my ($ldap, $dn, $pw, $noerr) = @_;
    my $res = $ldap->bind($dn, password => $pw);

    my $code = $res->code;
    my $err = $res->error;

    if ($code) {
	return undef if $noerr;
	die $err;
    }

    return 1;
}

sub query_users {
    my ($ldap, $filter, $attributes, $base_dn, $classes) = @_;

    # build filter from given filter and attribute list
    my $tmp = "(|";
    foreach my $att (@$attributes) {
	$tmp .= "($att=*)";
    }
    $tmp .= ")";

    if ($classes) {
	$tmp = "(&$tmp(|";
	for my $class (@$classes) {
	    $tmp .= "(objectclass=$class)";
	}
	$tmp .= "))";
    }

    if ($filter) {
	$filter = "($filter)" if $filter !~ m/^\(.*\)$/;
	$filter = "(&${filter}${tmp})"
    } else {
	$filter = $tmp;
    }

    my $page = Net::LDAP::Control::Paged->new(size => 900);

    my @args = (
	base     => $base_dn // "",
	scope    => "subtree",
	filter   => $filter,
	control  => [ $page ],
	attrs    => [ @$attributes, 'memberOf'],
    );

    my $cookie;
    my $err;
    my $users = [];

    while(1) {

	my $mesg = $ldap->search(@args);

	# stop on error
	if ($mesg->code)  {
	    $err = "ldap user search error: " . $mesg->error;
	    last;
	}

	#foreach my $entry ($mesg->entries) { $entry->dump; }
	foreach my $entry ($mesg->entries) {
	    my $user = {
		dn => $entry->dn,
		attributes => {},
		groups => [$entry->get_value('memberOf')],
	    };

	    foreach my $attr (@$attributes) {
		my $vals = [$entry->get_value($attr)];
		if (scalar(@$vals)) {
		    $user->{attributes}->{$attr} = $vals;
		}
	    }

	    push @$users, $user;
	}

	# Get cookie from paged control
	my ($resp) = $mesg->control(LDAP_CONTROL_PAGED) or last;
	$cookie = $resp->cookie;

	last if (!defined($cookie) || !length($cookie));

	# Set cookie in paged control
	$page->cookie($cookie);
    }

    if (defined($cookie) && length($cookie)) {
	# We had an abnormal exit, so let the server know we do not want any more
	$page->cookie($cookie);
	$page->size(0);
	$ldap->search(@args);
	$err = "LDAP user query unsuccessful" if !$err;
    }

    die $err if $err;

    return $users;
}

sub query_groups {
    my ($ldap, $base_dn, $classes, $filter, $group_name_attr) = @_;

    my $tmp = "(|";
    for my $class (@$classes) {
	$tmp .= "(objectclass=$class)";
    }
    $tmp .= ")";

    if ($filter) {
	$filter = "($filter)" if $filter !~ m/^\(.*\)$/;
	$filter = "(&${filter}${tmp})"
    } else {
	$filter = $tmp;
    }

    my $page = Net::LDAP::Control::Paged->new(size => 100);

    my $attrs = [ 'member', 'uniqueMember' ];
    push @$attrs, $group_name_attr if $group_name_attr;
    my @args = (
	base     => $base_dn,
	scope    => "subtree",
	filter   => $filter,
	control  => [ $page ],
	attrs    => $attrs,
    );

    my $cookie;
    my $err;
    my $groups = [];

    while(1) {

	my $mesg = $ldap->search(@args);

	# stop on error
	if ($mesg->code)  {
	    $err = "ldap group search error: " . $mesg->error;
	    last;
	}

	foreach my $entry ( $mesg->entries ) {
	    my $group = {
		dn => $entry->dn,
		members => []
	    };
	    my $members = [$entry->get_value('member')];
	    if (!scalar(@$members)) {
		$members = [$entry->get_value('uniqueMember')];
	    }
	    $group->{members} = $members;
	    if ($group_name_attr && (my $name = $entry->get_value($group_name_attr))) {
		$group->{name} = $name;
	    }
	    push @$groups, $group;
	}

	# Get cookie from paged control
	my ($resp) = $mesg->control(LDAP_CONTROL_PAGED) or last;
	$cookie = $resp->cookie;

	last if (!defined($cookie) || !length($cookie));

	# Set cookie in paged control
	$page->cookie($cookie);
    }

    if ($cookie) {
	# We had an abnormal exit, so let the server know we do not want any more
	$page->cookie($cookie);
	$page->size(0);
	$ldap->search(@args);
	$err = "LDAP group query unsuccessful" if !$err;
    }

    die $err if $err;

    return $groups;
}

1;
