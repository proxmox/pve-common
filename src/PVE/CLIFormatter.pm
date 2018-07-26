package PVE::CLIFormatter;

use strict;
use warnings;
use I18N::Langinfo;
use POSIX qw(strftime);
use CPAN::Meta::YAML; # comes with perl-modules

use PVE::JSONSchema;
use PVE::PTY;
use JSON;
use utf8;
use Encode;

sub render_timestamp {
    my ($epoch) = @_;

    # ISO 8601 date format
    return strftime("%F %H:%M:%S", localtime($epoch));
}

PVE::JSONSchema::register_renderer('timestamp', \&render_timestamp);

sub render_timestamp_gmt {
    my ($epoch) = @_;

    # ISO 8601 date format, standard Greenwich time zone
    return strftime("%F %H:%M:%S", gmtime($epoch));
}

PVE::JSONSchema::register_renderer('timestamp_gmt', \&render_timestamp_gmt);

sub render_duration {
    my ($duration_in_seconds) = @_;

    my $text = '';
    my $rest = $duration_in_seconds;

    my $step = sub {
	my ($unit, $unitlength) = @_;

	if ((my $v = int($rest/$unitlength)) > 0) {
	    $text .= " " if length($text);
	    $text .= "${v}${unit}";
	    $rest -= $v * $unitlength;
	}
    };

    $step->('w', 7*24*3600);
    $step->('d', 24*3600);
    $step->('h', 3600);
    $step->('m', 60);
    $step->('s', 1);

    return $text;
}

PVE::JSONSchema::register_renderer('duration', \&render_duration);

sub render_fraction_as_percentage {
    my ($fraction) = @_;

    return sprintf("%.2f%%", $fraction*100);
}

PVE::JSONSchema::register_renderer(
    'fraction_as_percentage', \&render_fraction_as_percentage);

sub render_bytes {
    my ($value) = @_;

    my @units = qw(B KiB MiB GiB TiB PiB);

    my $max_unit = 0;
    if ($value > 1023) {
        $max_unit = int(log($value)/log(1024));
        $value /= 1024**($max_unit);
    }

    return sprintf "%.2f $units[$max_unit]", $value;
}

PVE::JSONSchema::register_renderer('bytes', \&render_bytes);

sub render_yaml {
    my ($value) = @_;

    my $data = CPAN::Meta::YAML::Dump($value);
    $data =~ s/^---[\n\s]//; # remove yaml marker

    return $data;
}

PVE::JSONSchema::register_renderer('yaml', \&render_yaml);

sub query_terminal_options {
    my ($options) = @_;

    $options //= {};

    if (-t STDOUT) {
	($options->{columns}) = PVE::PTY::tcgetsize(*STDOUT);
    }

    $options->{encoding} = I18N::Langinfo::langinfo(I18N::Langinfo::CODESET());

    $options->{utf8} = 1 if $options->{encoding} eq 'UTF-8';

    return $options;
}

sub data_to_text {
    my ($data, $propdef, $options, $terminal_opts) = @_;

    return '' if !defined($data);

    $terminal_opts //= {};

    my $human_readable = $options->{'human-readable'} // 1;

     if ($human_readable && defined($propdef)) {
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
	    return $code->($data, $options, $terminal_opts);
	}
    }

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
# - sort_key: can be used to sort after a specific column, if it isn't set we sort
#   after the leftmost column (with no undef value in $data) this can be
#   turned off by passing 0 as sort_key
# - noborder: print without asciiart border
# - noheader: print without table header
# - columns: limit output width (if > 0)
# - utf8: use utf8 characters for table delimiters

sub print_text_table {
    my ($data, $returnprops, $props_to_print, $options, $terminal_opts) = @_;

    $terminal_opts //= query_terminal_options({});

    my $sort_key = $options->{sort_key};
    my $border = !$options->{noborder};
    my $header = !$options->{noheader};

    my $columns = $terminal_opts->{columns};
    my $utf8 = $terminal_opts->{utf8};
    my $encoding = $terminal_opts->{encoding} // 'UTF-8';

    $sort_key //= $props_to_print->[0];

    if (defined($sort_key) && $sort_key ne 0) {
	my $type = $returnprops->{$sort_key}->{type} // 'string';
	if ($type eq 'integer' || $type eq 'number') {
	    @$data = sort { $a->{$sort_key} <=> $b->{$sort_key} } @$data;
	} else {
	    @$data = sort { $a->{$sort_key} cmp $b->{$sort_key} } @$data;
	}
    }

    my $colopts = {};

    my $borderstring_m = '';
    my $borderstring_b = '';
    my $borderstring_t = '';
    my $formatstring = '';

    my $column_count = scalar(@$props_to_print);

    my $tabledata = [];

    foreach my $entry (@$data) {

	my $height = 1;
	my $rowdata = {};

	for (my $i = 0; $i < $column_count; $i++) {
	    my $prop = $props_to_print->[$i];
	    my $propinfo = $returnprops->{$prop} // {};

	    my $text = data_to_text($entry->{$prop}, $propinfo, $options, $terminal_opts);
	    my $lines = [ split(/\n/, $text) ];
	    my $linecount = scalar(@$lines);
	    $height = $linecount if $linecount > $height;

	    my $width = 0;
	    foreach my $line (@$lines) {
		my $len = length($line);
		$width = $len if $len > $width;
	    }

	    $rowdata->{$prop} = {
		lines => $lines,
		width => $width,
	    };
	}

	push @$tabledata, {
	    height => $height,
	    rowdata => $rowdata,
	};
    }

    for (my $i = 0; $i < $column_count; $i++) {
	my $prop = $props_to_print->[$i];
	my $propinfo = $returnprops->{$prop} // {};

	my $title = $propinfo->{title} // $prop;
	my $cutoff = $propinfo->{print_width} // $propinfo->{maxLength};

	# calculate maximal print width and cutoff
	my $titlelen = length($title);

	my $longest = $titlelen;
	foreach my $coldata (@$tabledata) {
	    my $rowdata = $coldata->{rowdata}->{$prop};
	    $longest = $rowdata->{width} if $rowdata->{width} > $longest;
	}
	$cutoff = $longest if !defined($cutoff) || $cutoff > $longest;

	$colopts->{$prop} = {
	    title => $title,
	    cutoff => $cutoff,
	};

	if ($border) {
	    if ($i == 0 && ($column_count == 1)) {
		if ($utf8) {
		    $formatstring .= "│ %-${cutoff}s │";
		    $borderstring_t .= "┌─" . ('─' x $cutoff) . "─┐";
		    $borderstring_m .= "├─" . ('─' x $cutoff) . "─┤";
		    $borderstring_b .= "└─" . ('─' x $cutoff) . "─┘";
		} else {
		    $formatstring .= "| %-${cutoff}s |";
		    $borderstring_m .= "+-" . ('-' x $cutoff) . "-+";
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
		    $formatstring .= "│ %-${cutoff}s │";
		    $borderstring_t .= "┬─" . ('─' x $cutoff) . "─┐";
		    $borderstring_m .= "┼─" . ('─' x $cutoff) . "─┤";
		    $borderstring_b .= "┴─" . ('─' x $cutoff) . "─┘";
		} else {
		    $formatstring .= "| %-${cutoff}s |";
		    $borderstring_m .= "+-" . ('-' x $cutoff) . "-+";
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
	    $formatstring .= ($i == ($column_count - 1)) ? "%s" : "%-${cutoff}s ";
	}
    }

    $borderstring_t = $borderstring_m if !length($borderstring_t);
    $borderstring_b = $borderstring_m if !length($borderstring_b);

    my $writeln = sub {
	my ($text) = @_;

	if ($columns) {
	    print encode($encoding, substr($text, 0, $columns) . "\n");
	} else {
	    print encode($encoding, $text) . "\n";
	}
    };

    $writeln->($borderstring_t) if $border;

    if ($header) {
	my $text = sprintf $formatstring, map { $colopts->{$_}->{title} } @$props_to_print;
	$writeln->($text);
    }

    for (my $i = 0; $i < scalar(@$tabledata); $i++) {
	my $coldata = $tabledata->[$i];

	$writeln->($borderstring_m) if $border && ($i != 0 || $header);

	for (my $i = 0; $i < $coldata->{height}; $i++) {

	    my $text = sprintf $formatstring, map {
		substr($coldata->{rowdata}->{$_}->{lines}->[$i] // '', 0, $colopts->{$_}->{cutoff});
	    } @$props_to_print;

	    $writeln->($text);
	}
    }

    $writeln->($borderstring_b) if $border;
}

sub extract_properties_to_print {
    my ($propdef) = @_;

    my $required = [];
    my $optional = [];

    foreach my $key (keys %$propdef) {
	my $prop = $propdef->{$key};
	if ($prop->{optional}) {
	    push @$optional, $key;
	} else {
	    push @$required, $key;
	}
    }

    return [ sort(@$required), sort(@$optional) ];
}

# prints the result of an API GET call returning an array as a table.
# takes formatting information from the results property of the call
# if $props_to_print is provided, prints only those columns. otherwise
# takes all fields of the results property, with a fallback
# to all fields occuring in items of $data.
sub print_api_list {
    my ($data, $result_schema, $props_to_print, $options, $terminal_opts) = @_;

    die "can only print object lists\n"
	if !($result_schema->{type} eq 'array' && $result_schema->{items}->{type} eq 'object');

    my $returnprops = $result_schema->{items}->{properties};

    $props_to_print = extract_properties_to_print($returnprops)
	if !defined($props_to_print);

    if (!scalar(@$props_to_print)) {
	my $all_props = {};
	foreach my $obj (@$data) {
	    foreach my $key (keys %$obj) {
		$all_props->{$key} = 1;
	    }
	}
	$props_to_print = [ sort keys %{$all_props} ];
    }

    die "unable to detect list properties\n" if !scalar(@$props_to_print);

    print_text_table($data, $returnprops, $props_to_print, $options, $terminal_opts);
}

sub print_api_result {
    my ($data, $result_schema, $props_to_print, $options, $terminal_opts) = @_;

    return if $options->{quiet};

    $terminal_opts //= query_terminal_options({});

    my $format = $options->{'output-format'} // 'text';

    return if $result_schema->{type} eq 'null';

    if ($format eq 'yaml') {
	print encode('UTF-8', CPAN::Meta::YAML::Dump($data));
    } elsif ($format eq 'json') {
	# Note: we always use utf8 encoding for json format
	print to_json($data, {utf8 => 1, allow_nonref => 1, canonical => 1 }) . "\n";
    } elsif ($format eq 'json-pretty') {
	# Note: we always use utf8 encoding for json format
	print to_json($data, {utf8 => 1, allow_nonref => 1, canonical => 1, pretty => 1 });
    } elsif ($format eq 'text') {
	my $encoding = $options->{encoding} // 'UTF-8';
	my $type = $result_schema->{type};
	if ($type eq 'object') {
	    $props_to_print = extract_properties_to_print($result_schema->{properties})
		if !defined($props_to_print);
	    $props_to_print = [ sort keys %$data ] if !scalar(@$props_to_print);
	    my $kvstore = [];
	    foreach my $key (@$props_to_print) {
		next if !defined($data->{$key});
		push @$kvstore, { key => $key, value => data_to_text($data->{$key}, $result_schema->{properties}->{$key}, $options, $terminal_opts) };
	    }
	    my $schema = { type => 'array', items => { type => 'object' }};
	    print_api_list($kvstore, $schema, ['key', 'value'], $options, $terminal_opts);
	} elsif ($type eq 'array') {
	    return if !scalar(@$data);
	    my $item_type = $result_schema->{items}->{type};
	    if ($item_type eq 'object') {
		print_api_list($data, $result_schema, $props_to_print, $options, $terminal_opts);
	    } else {
		my $kvstore = [];
		foreach my $value (@$data) {
		    push @$kvstore, { value => $value };
		}
		my $schema = { type => 'array', items => { type => 'object', properties => { value => $result_schema->{items} }}};
		print_api_list($kvstore, $schema, ['value'], { %$options, noheader => 1 },  $terminal_opts);
	    }
	} else {
	    print encode($encoding, "$data\n");
	}
    } else {
	die "internal error: unknown output format"; # should not happen
    }
}

1;
