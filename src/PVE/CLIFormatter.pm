package PVE::CLIFormatter;

use strict;
use warnings;

use I18N::Langinfo;
use YAML::XS; # supports Dumping JSON::PP::Boolean
$YAML::XS::Boolean = "JSON::PP";

use PVE::JSONSchema;
use PVE::PTY;
use PVE::Format;

use JSON;
use utf8;
use Encode;

PVE::JSONSchema::register_renderer('timestamp',
    \&PVE::Format::render_timestamp);
PVE::JSONSchema::register_renderer('timestamp_gmt',
    \&PVE::Format::render_timestamp_gmt);
PVE::JSONSchema::register_renderer('duration',
    \&PVE::Format::render_duration);
PVE::JSONSchema::register_renderer('fraction_as_percentage',
    \&PVE::Format::render_fraction_as_percentage);
PVE::JSONSchema::register_renderer('bytes',
    \&PVE::Format::render_bytes);

sub render_yaml {
    my ($value) = @_;

    my $data = YAML::XS::Dump($value);
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
	# JSON::PP::Boolean requires allow_nonref
	return to_json($data, { allow_nonref => 1, canonical => 1 });
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
#   after the leftmost column. This can be turned off by passing 0 as sort_key
# - noborder: print without asciiart border
# - noheader: print without table header
# - columns: limit output width (if > 0)
# - utf8: use utf8 characters for table delimiters

sub print_text_table {
    my ($data, $returnprops, $props_to_print, $options, $terminal_opts) = @_;

    $terminal_opts //= query_terminal_options({});

    my $sort_key = $options->{sort_key};
    my $show_border = !$options->{noborder};
    my $show_header = !$options->{noheader};

    my $columns = $terminal_opts->{columns};
    my $utf8 = $terminal_opts->{utf8};
    my $encoding = $terminal_opts->{encoding} // 'UTF-8';

    $sort_key //= $props_to_print->[0];

    if (defined($sort_key) && $sort_key ne 0) {
	my $type = $returnprops->{$sort_key}->{type} // 'string';
	my $cmpfn;
	if ($type eq 'integer' || $type eq 'number') {
	    $cmpfn = sub { $_[0] <=> $_[1] };
	} else {
	    $cmpfn = sub { $_[0] cmp $_[1] };
	}
	@$data = sort {
	    PVE::Tools::safe_compare($a->{$sort_key}, $b->{$sort_key}, $cmpfn)
	} @$data;
    }

    my $colopts = {};

    my $border = { m => '', b => '', t => '', h => '' };
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

	    $width = ($width =~ m/^(\d+)$/) ? int($1) : 0; # untaint int

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
	my $type = $propinfo->{type} // 'string';
	my $alignstr = ($type eq 'integer' || $type eq 'number') ? '' : '-';

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

	if ($show_border) {
	    if ($i == 0 && ($column_count == 1)) {
		if ($utf8) {
		    $formatstring .= "│ %$alignstr${cutoff}s │";
		    $border->{t} .= "┌─" . ('─' x $cutoff) . "─┐";
		    $border->{h} .= "╞═" . ('═' x $cutoff) . '═╡';
		    $border->{m} .= "├─" . ('─' x $cutoff) . "─┤";
		    $border->{b} .= "└─" . ('─' x $cutoff) . "─┘";
		} else {
		    $formatstring .= "| %$alignstr${cutoff}s |";
		    $border->{m} .= "+-" . ('-' x $cutoff) . "-+";
		    $border->{h} .= "+=" . ('=' x $cutoff) . '=';
		}
	    } elsif ($i == 0) {
		if ($utf8) {
		    $formatstring .= "│ %$alignstr${cutoff}s ";
		    $border->{t} .= "┌─" . ('─' x $cutoff) . '─';
		    $border->{h} .= "╞═" . ('═' x $cutoff) . '═';
		    $border->{m} .= "├─" . ('─' x $cutoff) . '─';
		    $border->{b} .= "└─" . ('─' x $cutoff) . '─';
		} else {
		    $formatstring .= "| %$alignstr${cutoff}s ";
		    $border->{m} .= "+-" . ('-' x $cutoff) . '-';
		    $border->{h} .= "+=" . ('=' x $cutoff) . '=';
		}
	    } elsif ($i == ($column_count - 1)) {
		if ($utf8) {
		    $formatstring .= "│ %$alignstr${cutoff}s │";
		    $border->{t} .= "┬─" . ('─' x $cutoff) . "─┐";
		    $border->{h} .= "╪═" . ('═' x $cutoff) . '═╡';
		    $border->{m} .= "┼─" . ('─' x $cutoff) . "─┤";
		    $border->{b} .= "┴─" . ('─' x $cutoff) . "─┘";
		} else {
		    $formatstring .= "| %$alignstr${cutoff}s |";
		    $border->{m} .= "+-" . ('-' x $cutoff) . "-+";
		    $border->{h} .= "+=" . ('=' x $cutoff) . "=+";
		}
	    } else {
		if ($utf8) {
		    $formatstring .= "│ %$alignstr${cutoff}s ";
		    $border->{t} .= "┬─" . ('─' x $cutoff) . '─';
		    $border->{h} .= "╪═" . ('═' x $cutoff) . '═';
		    $border->{m} .= "┼─" . ('─' x $cutoff) . '─';
		    $border->{b} .= "┴─" . ('─' x $cutoff) . '─';
		} else {
		    $formatstring .= "| %$alignstr${cutoff}s ";
		    $border->{m} .= "+-" . ('-' x $cutoff) . '-';
		    $border->{h} .= "+=" . ('=' x $cutoff) . '=';
		}
	    }
	} else {
	    # skip alignment and cutoff on last column
	    $formatstring .= ($i == ($column_count - 1)) ? "%s" : "%$alignstr${cutoff}s ";
	}
    }

    $border->{t} = $border->{m} if !length($border->{t});
    $border->{b} = $border->{m} if !length($border->{b});

    my $writeln = sub {
	my ($text) = @_;

	if ($columns) {
	    print encode($encoding, substr($text, 0, $columns) . "\n");
	} else {
	    print encode($encoding, $text) . "\n";
	}
    };

    $writeln->($border->{t}) if $show_border;

    if ($show_header) {
	my $text = sprintf $formatstring, map { $colopts->{$_}->{title} } @$props_to_print;
	$writeln->($text);
	$border->{sep} = $border->{h};
    } else {
	$border->{sep} = $border->{m};
    }

    for (my $i = 0; $i < scalar(@$tabledata); $i++) {
	my $coldata = $tabledata->[$i];

	if ($show_border && ($i != 0 || $show_header)) {
	    $writeln->($border->{sep});
	    $border->{sep} = $border->{m};
	}

	for (my $i = 0; $i < $coldata->{height}; $i++) {
	    my $text = sprintf $formatstring, map {
		substr($coldata->{rowdata}->{$_}->{lines}->[$i] // '', 0, $colopts->{$_}->{cutoff});
	    } @$props_to_print;

	    $writeln->($text);
	}
    }

    $writeln->($border->{b}) if $show_border;
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
# to all fields occurring in items of $data.
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

my $guess_type = sub {
    my $data = shift;

    return 'null' if !defined($data);

    my $class = ref($data);
    return 'string' if !$class;

    if ($class eq 'HASH') {
	return 'object';
    } elsif ($class eq 'ARRAY') {
	return 'array';
    } else {
	return 'string'; # better than nothing
    }
};

sub print_api_result {
    my ($data, $result_schema, $props_to_print, $options, $terminal_opts) = @_;

    return if $options->{quiet};

    $terminal_opts //= query_terminal_options({});

    my $format = $options->{'output-format'} // 'text';

    if ($result_schema && defined($result_schema->{type})) {
	return if $result_schema->{type} eq 'null';
	return if $result_schema->{optional} && !defined($data);
    } else {
	my $type = $guess_type->($data);
	$result_schema = { type => $type };
	$result_schema->{items} = { type => $guess_type->($data->[0]) } if $type eq 'array';
    }

    if ($format eq 'yaml') {
	print encode('UTF-8', YAML::XS::Dump($data));
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
	    if (ref($data) eq 'ARRAY') {
		return if !scalar(@$data);
	    } elsif (ref($data) eq 'HASH') {
		return if !scalar($data->%*);
		die "got hash object, but result schema specified array!\n"
	    }
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

sub print_api_result_plain {
    my ($data, $result_schema, $props_to_print, $options) = @_;

    # avoid borders and header, ignore terminal width
    $options = $options ? { %$options } : {}; # copy

    $options->{noheader} //= 1;
    $options->{noborder} //= 1;

    print_api_result($data, $result_schema, $props_to_print, $options, {});
}

1;
