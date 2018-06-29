package PVE::CLIFormatter;

use strict;
use warnings;
use PVE::JSONSchema;
use JSON;
use utf8;
use Encode;

sub println_max {
    my ($text, $max) = @_;

    if ($max) {
	my @lines = split(/\n/, $text);
	foreach my $line (@lines) {
	    print encode('UTF-8', substr($line, 0, $max) . "\n");
	}
    } else {
	print encode('UTF-8', $text);
    }
}

sub data_to_text {
    my ($data, $propdef) = @_;

    if (defined($propdef)) {
	if (my $type = $propdef->{type}) {
	    if ($type eq 'boolean') {
		return $data ? 1 : 0;
	    }
	}
	if (!defined($data) && defined($propdef->{default})) {
	    return "($propdef->{default})";
	}
	if (defined(my $renderer = $propdef->{renderer})) {
	    my $code = PVE::JSONSchema::get_renderer($renderer);
	    die "internal error: unknown renderer '$renderer'" if !$code;
	    return $code->($data);
	}
    }
    return '' if !defined($data);

    if (my $class = ref($data)) {
	return to_json($data, { canonical => 1 });
    } else {
	return "$data";
    }
}

# prints a formatted table with a title row.
# $data - the data to print (array of objects)
# $returnprops -json schema property description
# $props_to_print - ordered list of properties to print
# $options
# - sort_key: can be used to sort after a column, if it isn't set we sort
#   after the leftmost column (with no undef value in $data) this can be
#   turned off by passing 0 as sort_key
# - border: print with/without table header and asciiart border
# - columns: limit output width (if > 0)
# - utf8: use utf8 characters for table delimiters

sub print_text_table {
    my ($data, $returnprops, $props_to_print, $options) = @_;

    my $sort_key = $options->{sort_key};
    my $border = $options->{border};
    my $columns = $options->{columns};
    my $utf8 = $options->{utf8};

    my $autosort = 1;
    if (defined($sort_key) && $sort_key eq 0) {
	$autosort = 0;
	$sort_key = undef;
    }

    my $colopts = {};

    my $borderstring_m = '';
    my $borderstring_b = '';
    my $borderstring_t = '';
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
	    my $len = length(data_to_text($entry->{$prop}, $propinfo)) // 0;
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

	if ($border) {
	    if ($i == 0 && ($column_count == 1)) {
		if ($utf8) {
		    $formatstring .= "│ %-${cutoff}s │\n";
		    $borderstring_t .= "┌─" . ('─' x $cutoff) . "─┐\n";
		    $borderstring_m .= "├─" . ('─' x $cutoff) . "─┤\n";
		    $borderstring_b .= "└─" . ('─' x $cutoff) . "─┘\n";
		} else {
		    $formatstring .= "| %-${cutoff}s |\n";
		    $borderstring_m .= "+-" . ('-' x $cutoff) . "-+\n";
		}
	    } elsif ($i == 0) {
		if ($utf8) {
		    $formatstring .= "│ %-${cutoff}s ";
		    $borderstring_t .= "┌─" . ('─' x $cutoff) . '─';
		    $borderstring_m .= "├─" . ('─' x $cutoff) . '─';
		    $borderstring_b .= "└─" . ('─' x $cutoff) . '─';
		} else {
		    $formatstring .= "| %-${cutoff}s ";
		    $borderstring_m .= "+-" . ('-' x $cutoff) . '-';
		}
	    } elsif ($i == ($column_count - 1)) {
		if ($utf8) {
		    $formatstring .= "│ %-${cutoff}s │\n";
		    $borderstring_t .= "┬─" . ('─' x $cutoff) . "─┐\n";
		    $borderstring_m .= "┼─" . ('─' x $cutoff) . "─┤\n";
		    $borderstring_b .= "┴─" . ('─' x $cutoff) . "─┘\n";
		} else {
		    $formatstring .= "| %-${cutoff}s |\n";
		    $borderstring_m .= "+-" . ('-' x $cutoff) . "-+\n";
		}
	    } else {
		if ($utf8) {
		    $formatstring .= "│ %-${cutoff}s ";
		    $borderstring_t .= "┬─" . ('─' x $cutoff) . '─';
		    $borderstring_m .= "┼─" . ('─' x $cutoff) . '─';
		    $borderstring_b .= "┴─" . ('─' x $cutoff) . '─';
		} else {
		    $formatstring .= "| %-${cutoff}s ";
		    $borderstring_m .= "+-" . ('-' x $cutoff) . '-';
		}
	    }
	} else {
	    # skip alignment and cutoff on last column
	    $formatstring .= ($i == ($column_count - 1)) ? "%s\n" : "%-${cutoff}s ";
	}
    }

    if (defined($sort_key)) {
	my $type = $returnprops->{$sort_key}->{type} // 'string';
	if ($type eq 'integer' || $type eq 'number') {
	    @$data = sort { $a->{$sort_key} <=> $b->{$sort_key} } @$data;
	} else {
	    @$data = sort { $a->{$sort_key} cmp $b->{$sort_key} } @$data;
	}
    }

    $borderstring_t = $borderstring_m if !length($borderstring_t);
    $borderstring_b = $borderstring_m if !length($borderstring_b);

    println_max($borderstring_t, $columns) if $border;
    my $text = sprintf $formatstring, map { $colopts->{$_}->{title} } @$props_to_print;
    println_max($text, $columns);

    foreach my $entry (@$data) {
	println_max($borderstring_m, $columns) if $border;
        $text = sprintf $formatstring, map {
	    substr(data_to_text($entry->{$_}, $returnprops->{$_}) // $colopts->{$_}->{default},
		   0, $colopts->{$_}->{cutoff});
	} @$props_to_print;
	println_max($text, $columns);
    }
    println_max($borderstring_b, $columns) if $border;
}

# prints the result of an API GET call returning an array as a table.
# takes formatting information from the results property of the call
# if $props_to_print is provided, prints only those columns. otherwise
# takes all fields of the results property, with a fallback
# to all fields occuring in items of $data.
sub print_api_list {
    my ($data, $result_schema, $props_to_print, $options) = @_;

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

    print_text_table($data, $returnprops, $props_to_print, $options);
}

sub print_api_result {
    my ($format, $data, $result_schema, $props_to_print, $options) = @_;

    $options //= {};
    $options = { %$options }; # copy

    return if $result_schema->{type} eq 'null';

    if ($format eq 'json') {
	print to_json($data, {utf8 => 1, allow_nonref => 1, canonical => 1, pretty => 1 });
    } elsif ($format eq 'text' || $format eq 'plain') {
	my $type = $result_schema->{type};
	if ($type eq 'object') {
	    $props_to_print = [ sort keys %$data ] if !defined($props_to_print);
	    my $kvstore = [];
	    foreach my $key (@$props_to_print) {
		push @$kvstore, { key => $key, value => data_to_text($data->{$key}, $result_schema->{properties}->{$key}) };
	    }
	    my $schema = { type => 'array', items => { type => 'object' }};
	    $options->{border} = $format eq 'text';
	    print_api_list($kvstore, $schema, ['key', 'value'], $options);
	} elsif ($type eq 'array') {
	    return if !scalar(@$data);
	    my $item_type = $result_schema->{items}->{type};
	    if ($item_type eq 'object') {
		$options->{border} = $format eq 'text';
		print_api_list($data, $result_schema, $props_to_print, $options);
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
