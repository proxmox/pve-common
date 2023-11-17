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
	field2 => {
	    description => 'Field Two',
	    type => 'integer',
	    minimum => 10,
	    maximum => 19,
	},
	another => {
	    description => 'Another field',
	    type => 'string',
	    optional => 1,
	},
	arrayfield => {
	    description => "Array Field with property string",
	    optional => 1,
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
	    description => 'Field Two but different',
	    type => 'integer',
	    minimum => 3,
	    maximum => 9,
	},
	another => {
	    description => 'Another field',
	    type => 'string',
	},
	arrayfield => {
	    optional => 1,
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
    };
}

package main;

use strict;
use warnings;

use Test::More;

Conf::One->register();
Conf::Two->register();
Conf->init(property_isolation => 1);

# FIXME: allow development debug warnings?!
local $SIG{__WARN__} = sub { die @_; };

my sub enum {
    my $n = 1;
    return { map { $_ => $n++ } @_ };
}

Conf->expect_success(
    'property-isolation-test1',
    {
	ids => {
	    t1 => {
		type => 'one',
		common => 'foo',
		field1 => 3,
		field2 => 10,
		arrayfield => [ 'subfield1=test' ],
	    },
	    t2 => {
		type => 'one',
		common => 'foo2',
		field1 => 4,
		field2 => 15,
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
	field2 10
	arrayfield subfield1=test

one: t2
	common foo2
	field1 4
	field2 15
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
	    field2 => 10,
	},
	t2 => {
	    type => 'one',
	    common => 'foo2',
	    field1 => 4,
	    field2 => 15,
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
	    unknownarray => ['entry1', 'entry2'],
	},
    },
    order => enum(qw(t1 t2 invalid t3)),
};
my $with_unknown_text = <<"EOF";
one: t1
	common foo
	field1 3
	field2 10

one: t2
	common foo2
	field1 4
	field2 15
	another more-text

bad: invalid
	common omg
	unknownfield shouldnotbehere
	unknownarray entry1
	unknownarray entry2

two: t3
	field2 5
	another even more text
	arrayfield subfield1=test,subfield2=2
	arrayfield subfield1=test2
EOF

my $wrong_field_schema_data = {
    ids => {
	t1 => {
	    type => 'one',
	    common => 'foo',
	    field1 => 3,
	    field2 => 5, # this should fail
	},
    },
    order => enum(qw(t1)),
};

my $wrong_field_schema_text = <<"EOF";
one: t1
	common foo
	field1 3
	field2 5
EOF

Conf->expect_fail('property-isolation-wrong-field-schema', $wrong_field_schema_data, $wrong_field_schema_text);
Conf->expect_fail('property-isolation-unknown-forbidden', $with_unknown_data, $with_unknown_text);
Conf->expect_success('property-isolation-unknown-allowed', $with_unknown_data, $with_unknown_text, 1);

# schema tests
my $create_schema = Conf->createSchema();
my $expected_create_schema = {
    additionalProperties => 0,
    type => 'object',
    properties => {
	id => {
	    description => "ID",
	    type => 'string',
	    format => 'pve-configid',
	    maxLength => 64,
	},
	type => {
	    description => 'Section type.',
	    enum => [ 'one', 'two' ],
	    type => 'string'
	},
	common => {
	    maxLength => 512,
	    optional => 1,
	    type => 'string',
	    description => 'common value'
	},
	field1 => {
	    type => 'integer',
	    'type-property' => 'type',
	    'instance-types' => [ 'one' ],
	    maximum => 9,
	    optional => 1,
	    minimum => 3,
	    description => 'Field One'
	},
	field2 => {
	    oneOf => [
		{
		    description => 'Field Two',
		    optional => 1,
		    minimum => 10,
		    'instance-types' => [ 'one' ],
		    type => 'integer',
		    maximum => 19
		},
		{
		    optional => 1,
		    minimum => 3,
		    description => 'Field Two but different',
		    type => 'integer',
		    'instance-types' => [ 'two' ],
		    maximum => 9
		}
	    ],
	    'type-property' => 'type'
	},
	arrayfield => {
	    items => {
		type => 'string',
		format => {
		    subfield1 => {
			description => 'first subfield',
			type => 'string'
		    },
		    subfield2 => {
			minimum => 0,
			type => 'integer',
			optional => 1
		    }
		},
		description => 'a property string'
	    },
	    description => 'Array Field with property string',
	    type => 'array',
	    optional => 1
	},
	another => {
	    optional => 1,
	    type => 'string',
	    description => 'Another field'
	},
    },
};

is_deeply($create_schema, $expected_create_schema, "property-isolation create schema test");

my $update_schema = Conf->updateSchema();
my $expected_update_schema = {
    additionalProperties => 0,
    type => 'object',
    properties => {
	id => {
	    description => "ID",
	    type => 'string',
	    format => 'pve-configid',
	    maxLength => 64,
	},
	type => {
	    type => 'string',
	    enum => [ 'one', 'two' ],
	    description => 'Section type.'
	},
	digest => {
	    optional => 1,
	    type => 'string',
	    description => 'Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.',
	    maxLength => 64
	},
	delete => {
	    description => 'A list of settings you want to delete.',
	    maxLength => 4096,
	    format => 'pve-configid-list',
	    optional => 1,
	    type => 'string'
	},
	common => {
	    maxLength => 512,
	    description => 'common value',
	    type => 'string',
	    optional => 1
	},
	field1 => {
	    description => 'Field One',
	    maximum => 9,
	    'instance-types' => [ 'one' ],
	    'type-property' => 'type',
	    minimum => 3,
	    optional => 1,
	    type => 'integer'
	},
	field2 => {
	    'type-property' => 'type',
	    oneOf => [
		{
		    type => 'integer',
		    minimum => 10,
		    optional => 1,
		    maximum => 19,
		    'instance-types' => [ 'one' ],
		    description => 'Field Two'
		},
		{
		    description => 'Field Two but different',
		    maximum => 9,
		    'instance-types' => [ 'two' ],
		    minimum => 3,
		    optional => 1,
		    type => 'integer'
		}
	    ]
	},
	arrayfield => {
	    type => 'array',
	    optional => 1,
	    items => {
		description => 'a property string',
		type => 'string',
		format => {
		    subfield2 => {
			type => 'integer',
			minimum => 0,
			optional => 1
		    },
		    subfield1 => {
			description => 'first subfield',
			type => 'string'
		    }
		}
	    },
	    description => 'Array Field with property string'
	},
	another => {
	    description => 'Another field',
	    optional => 1,
	    type => 'string'
	},
    }
};
is_deeply($update_schema, $expected_update_schema, "property-isolation update schema test");

done_testing();

1;
