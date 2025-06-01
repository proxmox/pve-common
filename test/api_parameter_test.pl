#!/usr/bin/perl
package PVE::TestAPIParameters;

# Tests the automatic conversion of -list and array parameter types

use strict;
use warnings;

use lib '../src';

use PVE::RESTHandler;
use PVE::JSONSchema;

use Test::More;

use base qw(PVE::RESTHandler);

my $setup = [
    {
        name => 'list-format-with-list',
        parameter => {
            type => 'string',
            format => 'pve-configid-list',
        },
        value => "foo,bar",
        'value-expected' => "foo,bar",
    },
    {
        name => 'array-format-with-array',
        parameter => {
            type => 'array',
            items => {
                type => 'string',
                format => 'pve-configid',
            },
        },
        value => ['foo', 'bar'],
        'value-expected' => ['foo', 'bar'],
    },
    # TODO: below behaviour should be deprecated with 9.x and fail with 10.x
    {
        name => 'list-format-with-alist',
        parameter => {
            type => 'string',
            format => 'pve-configid-list',
        },
        value => "foo\0bar",
        'value-expected' => "foo\0bar",
    },
    {
        name => 'array-format-with-non-array',
        parameter => {
            type => 'array',
            items => {
                type => 'string',
                format => 'pve-configid',
            },
        },
        value => "foo",
        'value-expected' => ['foo'],
    },
    {
        name => 'list-format-with-array',
        parameter => {
            type => 'string',
            format => 'pve-configid-list',
        },
        value => ['foo', 'bar'],
        'value-expected' => "foo,bar",
    },
];

for my $data ($setup->@*) {
    __PACKAGE__->register_method({
        name => $data->{name},
        path => $data->{name},
        method => 'POST',
        parameters => {
            additionalProperties => 0,
            properties => {
                param => $data->{parameter},
            },
        },
        returns => { type => 'null' },
        code => sub {
            my ($param) = @_;
            return $param->{param};
        },
    });

    my ($handler, $info) = __PACKAGE__->find_handler('POST', $data->{name});
    my $param = {
        param => $data->{value},
    };

    my $res = $handler->handle($info, $param);
    is_deeply($res, $data->{'value-expected'}, $data->{name});
}

done_testing();
