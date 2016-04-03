package PVE::PodParser;

use strict;
use warnings;
use Pod::Parser;
use base qw(Pod::Parser);

my $currentYear = (localtime(time))[5] + 1900;

my $stdinclude = {
    pve_copyright => <<EODATA,
\=head1 COPYRIGHT AND DISCLAIMER

Copyright (C) 2007-$currentYear Proxmox Server Solutions GmbH

This program is free software: you can redistribute it and\/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see L<http://www.gnu.org/licenses/>.
EODATA
};

sub command { 
    my ($self, $cmd, $text, $line_num, $pod_para)  = @_;

    if (($cmd eq 'include' && $text =~ m/^\s*(\S+)\s/)) {
	my $incl = $1;
	my $data = $stdinclude->{$incl} ? $stdinclude->{$incl} :
	    $self->{include}->{$incl};
	chomp $data;
	$self->textblock("$data\n\n", $line_num, $pod_para);
    } else {
	$self->textblock($pod_para->raw_text(), $line_num, $pod_para);
    }
}

# helpers used to generate our manual pages

sub generate_typetext {
    my ($schema) = @_;
    my $typetext = '';
    my (@optional, @required);
    foreach my $key (sort keys %$schema) {
	my $entry = $schema->{$key};
	next if $entry->{alias};
	next if !$entry->{format_description} &&
	        !$entry->{typetext} &&
	        !$entry->{enum} &&
	        $entry->{type} ne 'boolean';
	if ($schema->{$key}->{optional}) {
	    push @optional, $key;
	} else {
	    push @required, $key;
	}
    }
    my ($pre, $post) = ('', '');
    my $add = sub {
	my ($key) = @_;
	$typetext .= $pre;
	my $entry = $schema->{$key};
	if (my $alias = $entry->{alias}) {
	    $key = $alias;
	    $entry = $schema->{$key};
	}
	if (!defined($entry->{typetext})) {
	    $typetext .= $entry->{default_key} ? "[$key=]" : "$key=";
	}
	if (my $desc = $entry->{format_description}) {
	    $typetext .= "<$desc>";
	} elsif (my $text = $entry->{typetext}) {
	    $typetext .= $text;
	} elsif (my $enum = $entry->{enum}) {
	    $typetext .= '<' . join('|', @$enum) . '>';
	} elsif ($entry->{type} eq 'boolean') {
	    $typetext .= '<1|0>';
	} else {
	    die "internal error: neither format_description nor typetext found";
	}
	$typetext .= $post;
    };
    foreach my $key (@required) {
	&$add($key);
	$pre = ', ';
    }
    $pre = $pre ? ' [,' : '[';
    $post = ']';
    foreach my $key (@optional) {
	&$add($key);
	$pre = ' [,';
    }
    return $typetext;
}

sub schema_get_type_text {
    my ($phash) = @_;

    if ($phash->{typetext}) {
	return $phash->{typetext};
    } elsif ($phash->{enum}) {
	return "(" . join(' | ', sort @{$phash->{enum}}) . ")";
    } elsif ($phash->{pattern}) {
	return $phash->{pattern};
    } elsif ($phash->{type} eq 'integer' || $phash->{type} eq 'number') {
	if (defined($phash->{minimum}) && defined($phash->{maximum})) {
	    return "$phash->{type} ($phash->{minimum} - $phash->{maximum})";
	} elsif (defined($phash->{minimum})) {
	    return "$phash->{type} ($phash->{minimum} - N)";
	} elsif (defined($phash->{maximum})) {
	    return "$phash->{type} (-N - $phash->{maximum})";
	}
    } elsif ($phash->{type} eq 'string') {
	if (my $format = $phash->{format}) {
	    $format = PVE::JSONSchema::get_format($format) if ref($format) ne 'HASH';
	    if (ref($format) eq 'HASH') {
		return generate_typetext($format);
	    }
	}
    }

    my $type = $phash->{type} || 'string';

    return $type;
}

sub generate_property_text {
    my ($schema) = @_;
    my $data = '';
    foreach my $key (sort keys %$schema) {
	my $d = $schema->{$key};
	next if $d->{alias};
	my $desc = $d->{description};
	my $typetext = schema_get_type_text($d);
	$desc = 'No description available' if !$desc;
	$data .= "=item $key: $typetext\n\n$desc\n\n";
    }
    return $data;
}

# generate pod from JSON schema properties
sub dump_properties {
    my ($properties) = @_;

    my $data = "=over 1\n\n";

    my $idx_param = {}; # -vlan\d+ -scsi\d+

    foreach my $key (sort keys %$properties) {
	my $d = $properties->{$key};
	my $base = $key;
	if ($key =~ m/^([a-z]+)(\d+)$/) {
	    my $name = $1;
	    next if $idx_param->{$name};
	    $idx_param->{$name} = 1;
	    $base = "${name}[n]";
	}

	my $descr = $d->{description} || 'No description avalable.';
	chomp $descr;

	if (defined(my $dv = $d->{default})) {
	    my $multi = $descr =~ m/\n\n/; # multi paragraph ?
	    $descr .= $multi ? "\n\n" : " ";
	    $descr .= "Default value is '$dv'.";
	}

	my $typetext = schema_get_type_text($d);
	$data .= "=item $base: $typetext\n\n";
	$data .= "$descr\n\n";

	if ($d->{type} eq 'string') {
	    my $format = $d->{format};
	    if ($format && ref($format) eq 'HASH') {
		$data .= "=over 1.1\n\n";
		$data .= generate_property_text($format);
		$data .= "=back\n\n";
	    }
	}
    }

    $data .= "=back";

    return $data;
}

1;
