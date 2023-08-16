#!/usr/bin/perl

use lib '../src';

package Conf;
use strict;
use warnings;

use Test::More;

use base qw(PVE::SectionConfig);

my $defaultData = {
    propertyList => {
	type => { description => "Section type." },
	id => {
	    description => "ID",
	    type => 'string',
	    format => 'pve-configid',
	    maxLength => 64,
	},
	common => {
	    type => 'string',
	    description => 'common value',
	    maxLength => 512,
	},
    },
};

sub private {
    return $defaultData;
}

sub expect_success {
    my ($class, $filename, $expected, $raw, $allow_unknown) = @_;

    my $res = $class->parse_config($filename, $raw, $allow_unknown);
    delete $res->{digest};

    is_deeply($res, $expected, $filename);

    my $written = $class->write_config($filename, $res, $allow_unknown);
    my $res2 = $class->parse_config($filename, $written, $allow_unknown);
    delete $res2->{digest};

    is_deeply($res, $res2, "$filename - verify rewritten data");
}

sub expect_fail {
    my ($class, $filename, $expected, $raw) = @_;

    eval { $class->parse_config($filename, $raw) };
    die "test '$filename' succeeded unexpectedly\n" if !$@;
    ok(1, "$filename should fail to parse");
}

package Conf::One;
use strict;
use warnings;

use base 'Conf';

sub type {
    return 'one';
}

sub properties {
    return {
	field1 => {
	    description => 'Field One',
	    type => 'integer',
	    minimum => 3,
	    maximum => 9,
	},
	another => {
	    description => 'Another field',
	    type => 'string',
	},
    };
}

sub options {
    return {
	common => { optional => 1 },
	field1 => {},
	another => { optional => 1 },
    };
}

package Conf::Two;
use strict;
use warnings;

use base 'Conf';

sub type {
    return 'two';
}

sub properties {
    return {
	field2 => {
	    description => 'Field Two',
	    type => 'integer',
	    minimum => 3,
	    maximum => 9,
	},
	arrayfield => {
	    description => "Array Field with property string",
	    type => 'array',
	    items => {
		type => 'string',
		description => 'a property string',
		format => {
		    subfield1 => {
			type => 'string',
			description => 'first subfield'
		    },
		    subfield2 => {
			type => 'integer',
			minimum => 0,
			optional => 1,
		    },
		},
	    },
	},
    };
}

sub options {
    return {
	common => { optional => 1 },
	field2 => {},
	another => {},
	arrayfield => { optional => 1 },
    };
}

package main;

use strict;
use warnings;

use Test::More;

Conf::One->register();
Conf::Two->register();
Conf->init();

# FIXME: allow development debug warnings?!
local $SIG{__WARN__} = sub { die @_; };

my sub enum {
    my $n = 1;
    return { map { $_ => $n++ } @_ };
}

Conf->expect_success(
    'test1',
    {
	ids => {
	    t1 => {
		type => 'one',
		common => 'foo',
		field1 => 3,
	    },
	    t2 => {
		type => 'one',
		common => 'foo2',
		field1 => 4,
		another => 'more-text',
	    },
	    t3 => {
		type => 'two',
		field2 => 5,
		another => 'even more text',
	    },
	},
	order => { t1 => 1, t2 => 2, t3 => 3 },
    },
    <<"EOF");
one: t1
	common foo
	field1 3

one: t2
	common foo2
	field1 4
	another more-text

two: t3
	field2 5
	another even more text
EOF

my $with_unknown_data = {
    ids => {
	t1 => {
	    type => 'one',
	    common => 'foo',
	    field1 => 3,
	},
	t2 => {
	    type => 'one',
	    common => 'foo2',
	    field1 => 4,
	    another => 'more-text',
	},
	t3 => {
	    type => 'two',
	    field2 => 5,
	    another => 'even more text',
	    arrayfield => [
		'subfield1=test,subfield2=2',
		'subfield1=test2',
	    ],
	},
	invalid => {
	    type => 'bad',
	    common => 'omg',
	    unknownfield => 'shouldnotbehere',
	},
    },
    order => enum(qw(t1 t2 invalid t3)),
};
my $with_unknown_text = <<"EOF";
one: t1
	common foo
	field1 3

one: t2
	common foo2
	field1 4
	another more-text

bad: invalid
	common omg
	unknownfield shouldnotbehere

two: t3
	field2 5
	another even more text
	arrayfield subfield1=test,subfield2=2
	arrayfield subfield1=test2
EOF

Conf->expect_fail('unknown-forbidden', $with_unknown_data, $with_unknown_text);
Conf->expect_success('unknown-allowed', $with_unknown_data, $with_unknown_text, 1);


done_testing();

1;
