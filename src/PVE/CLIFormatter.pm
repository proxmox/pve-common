package PVE::CLIFormatter;

use strict;
use warnings;
use JSON;

sub data_to_text {
    my ($data) = @_;

    return '' if !defined($data);

    if (my $class = ref($data)) {
	return to_json($data, { utf8 => 1, canonical => 1 });
    } else {
	return "$data";
    }
}

# prints a formatted table with a title row.
# $data - the data to print (array of objects)
# $returnprops -json schema property description
# $props_to_print - ordered list of properties to print
# $sort_key can be used to sort after a column, if it isn't set we sort
#   after the leftmost column (with no undef value in $data) this can be
#   turned off by passing 0 as $sort_key
sub print_text_table {
    my ($data, $returnprops, $props_to_print, $sort_key) = @_;

    my $autosort = 1;
    if (defined($sort_key) && $sort_key eq 0) {
	$autosort = 0;
	$sort_key = undef;
    }

    my $colopts = {};
    my $formatstring = '';

    my $column_count = scalar(@$props_to_print);

    for (my $i = 0; $i < $column_count; $i++) {
	my $prop = $props_to_print->[$i];
	my $propinfo = $returnprops->{$prop} // {};

	my $title = $propinfo->{title} // $prop;
	my $cutoff = $propinfo->{print_width} // $propinfo->{maxLength};

	# calculate maximal print width and cutoff
	my $titlelen = length($title);

	my $longest = $titlelen;
	my $sortable = $autosort;
	foreach my $entry (@$data) {
	    my $len = length(data_to_text($entry->{$prop})) // 0;
	    $longest = $len if $len > $longest;
	    $sortable = 0 if !defined($entry->{$prop});
	}
	$cutoff = $longest if !defined($cutoff) || $cutoff > $longest;
	$sort_key //= $prop if $sortable;

	$colopts->{$prop} = {
	    title => $title,
	    default => $propinfo->{default} // '',
	    cutoff => $cutoff,
	};

	# skip alignment and cutoff on last column
	$formatstring .= ($i == ($column_count - 1)) ? "%s\n" : "%-${cutoff}s ";
    }

    printf $formatstring, map { $colopts->{$_}->{title} } @$props_to_print;

    if (defined($sort_key)) {
	my $type = $returnprops->{$sort_key}->{type} // 'string';
	if ($type eq 'integer' || $type eq 'number') {
	    @$data = sort { $a->{$sort_key} <=> $b->{$sort_key} } @$data;
	} else {
	    @$data = sort { $a->{$sort_key} cmp $b->{$sort_key} } @$data;
	}
    }

    foreach my $entry (@$data) {
        printf $formatstring, map {
	    substr(data_to_text($entry->{$_}) // $colopts->{$_}->{default},
		   0, $colopts->{$_}->{cutoff});
	} @$props_to_print;
    }
}

# prints the result of an API GET call returning an array as a table.
# takes formatting information from the results property of the call
# if $props_to_print is provided, prints only those columns. otherwise
# takes all fields of the results property, with a fallback
# to all fields occuring in items of $data.
sub print_api_list {
    my ($data, $result_schema, $props_to_print, $sort_key) = @_;

    die "can only print object lists\n"
	if !($result_schema->{type} eq 'array' && $result_schema->{items}->{type} eq 'object');

    my $returnprops = $result_schema->{items}->{properties};

    if (!defined($props_to_print)) {
	$props_to_print = [ sort keys %$returnprops ];
	if (!scalar(@$props_to_print)) {
	    my $all_props = {};
	    foreach my $obj (@{$data}) {
		foreach my $key (keys %{$obj}) {
		    $all_props->{ $key } = 1;
		}
	    }
	    $props_to_print = [ sort keys %{$all_props} ];
	}
	die "unable to detect list properties\n" if !scalar(@$props_to_print);
    }

    print_text_table($data, $returnprops, $props_to_print, $sort_key);
}

sub print_api_result {
    my ($format, $data, $result_schema, $props_to_print, $sort_key) = @_;

    return if $result_schema->{type} eq 'null';

    if ($format eq 'json') {
	print to_json($data, {utf8 => 1, allow_nonref => 1, canonical => 1, pretty => 1 });
    } elsif ($format eq 'text') {
	my $type = $result_schema->{type};
	if ($type eq 'object') {
	    $props_to_print = [ sort keys %$data ] if !defined($props_to_print);
	    foreach my $key (@$props_to_print) {
		print $key . ": " .  data_to_text($data->{$key}) . "\n";
	    }
	} elsif ($type eq 'array') {
	    return if !scalar(@$data);
	    my $item_type = $result_schema->{items}->{type};
	    if ($item_type eq 'object') {
		print_api_list($data, $result_schema, $props_to_print, $sort_key);
	    } else {
		foreach my $entry (@$data) {
		    print data_to_text($entry) . "\n";
		}
	    }
	} else {
	    print "$data\n";
	}
    } else {
	die "internal error: unknown output format"; # should not happen
    }
}

1;
