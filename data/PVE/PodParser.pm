package PVE::PodParser;

use strict;
use Pod::Parser;
use base qw(Pod::Parser);

my $stdinclude = {
    pve_copyright => <<EODATA,
\=head1 COPYRIGHT AND DISCLAIMER

Copyright (C) 2007-2011 Proxmox Server Solutions GmbH

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
    }

    my $type = $phash->{type} || 'string';

    return $type;
}

# generta epop from JSON schema properties
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
    }

    $data .= "=back";

    return $data;
}

1;
