#!/usr/bin/perl
# Tests the PVE::Certificate::check_pem function for
# correctness and coverage of edgecases.
use strict;
use warnings;

use lib '../src';

use Test::More;

use PVE::Certificate;

# Arrange
my $setup = [
    {
        expected_success => 1,
        name => "full pem",
        pem => <<'EOF',
-----BEGIN CERTIFICATE-----
MIIBsjCCAVugAwIBAgIJAO2g8Z0dXk9tMAoGCCqGSM49BAMCMEUxCzAJBgNVBAYT
AlVTMQswCQYDVQQIDAJDQTEQMA4GA1UEBwwHQmVya2VsZXkxEDAOBgNVBAoMB1Rl
c3QgQ0EwHhcNMjAwMTAxMDAwMDAwWhcNMzAwMTAxMDAwMDAwWjBFMQswCQYDVQQG
EwJVUzELMAkGA1UECAwCQ0ExEDAOBgNVBAcMB0JlcmtlbGV5MRAwDgYDVQQKDAdU
ZXN0IENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEv5Q8q1p7qZ2gqkQ0Qn5x
0n9yqv8n8n7n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8aNT
MFEwHQYDVR0OBBYEFOu2Y0bq8v3z7qkq1m1Qwqkq1m1QMB8GA1UdIwQYMBaAFOu2
Y0bq8v3z7qkq1m1Qwqkq1m1QMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwID
SAAwRQIhANfakefakefakefakefakefakefakefakefake
-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 1,
        name => "other label pem",
        label => "SOME LABEL",
        pem => <<'EOF',
-----BEGIN SOME LABEL-----
MIIBsjCCAVugAwIBAgIJAO2g8Z0dXk9tMAoGCCqGSM49BAMCMEUxCzAJBgNVBAYT
AlVTMQswCQYDVQQIDAJDQTEQMA4GA1UEBwwHQmVya2VsZXkxEDAOBgNVBAoMB1Rl
c3QgQ0EwHhcNMjAwMTAxMDAwMDAwWhcNMzAwMTAxMDAwMDAwWjBFMQswCQYDVQQG
EwJVUzELMAkGA1UECAwCQ0ExEDAOBgNVBAcMB0JlcmtlbGV5MRAwDgYDVQQKDAdU
ZXN0IENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEv5Q8q1p7qZ2gqkQ0Qn5x
0n9yqv8n8n7n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8n8aNT
MFEwHQYDVR0OBBYEFOu2Y0bq8v3z7qkq1m1Qwqkq1m1QMB8GA1UdIwQYMBaAFOu2
Y0bq8v3z7qkq1m1Qwqkq1m1QMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwID
SAAwRQIhANfakefakefakefakefakefakefakefakefake
-----END SOME LABEL-----
EOF
    },
    {
        expected_success => 1,
        name => "simple pem",
        pem => <<'EOF',
-----BEGIN CERTIFICATE-----
test
-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 1,
        name => "spaced out pem",
        pem => <<'EOF',
-----BEGIN CERTIFICATE-----

test

-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 1,
        name => "only newline pem",
        pem => <<'EOF',
-----BEGIN CERTIFICATE-----
-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 1,
        name => "many newlines pem",
        pem => <<'EOF',
-----BEGIN CERTIFICATE-----



-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 0,
        name => "no content pem",
        pem => <<'EOF',
-----BEGIN CERTIFICATE----------END CERTIFICATE-----
EOF
    },
    {
        expected_success => 1,
        name => "preceding content pem",
        pem => <<'EOF',
some extended content
-----BEGIN CERTIFICATE-----
test
-----END CERTIFICATE-----
EOF

        expected_result => <<'EOF',
-----BEGIN CERTIFICATE-----
test
-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 0,
        name => "following content pem",
        pem => <<'EOF',
-----BEGIN CERTIFICATE-----
test
-----END CERTIFICATE-----
some extended content
EOF
    },
    {
        expected_success => 0,
        name => "empty pem",
        pem => <<'EOF',

EOF
    },
    {
        expected_success => 0,
        name => "upsidedown pem",
        pem => <<'EOF',
-----END CERTIFICATE-----
test
-----BEGIN CERTIFICATE-----
EOF
    },
    {
        expected_success => 1,
        name => "multi pem",
        multiple => 1,
        pem => <<'EOF',
-----BEGIN CERTIFICATE-----
12JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
22JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
32JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
42JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 0,
        name => "multiple as single pem",
        pem => <<'EOF',
Subject: CN=some.test.content
Issuer: CN=Org Issuing CA 3
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
Subject: CN=Org Issuing CA 3
Issuer: CN=Org Root CA
-----BEGIN CERTIFICATE-----
2WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 1,
        name => "multiple pem",
        multiple => 1,
        pem => <<'EOF',
Subject: CN=some.test.content
Issuer: CN=Org Issuing CA 3
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
Subject: CN=Org Issuing CA 3
Issuer: CN=Org Root CA
-----BEGIN CERTIFICATE-----
2WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
        expected_result => <<'EOF',
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
2WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 1,
        name => "big pem different label",
        multiple => 1,
        label => "LABEL",
        pem => <<'EOF',
Subject: CN=some.test.content
Issuer: CN=Org Issuing CA 3
-----BEGIN LABEL-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END LABEL-----
Subject: CN=Org Issuing CA 3
Issuer: CN=Org Root CA
-----BEGIN LABEL-----
2WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END LABEL-----
Subject: CN=Org Root CA
Issuer: CN=Org Root CA
-----BEGIN LABEL-----
3WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END LABEL-----
EOF

        expected_result => <<'EOF',
-----BEGIN LABEL-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END LABEL-----
-----BEGIN LABEL-----
2WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END LABEL-----
-----BEGIN LABEL-----
3WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END LABEL-----
EOF
    },
    {
        expected_success => 1,
        name => "other real pem",
        pem => <<'EOF',
Subject: CN=Some subject with 2 Points,O=A Organization,L=Some Lation,C=TT
Issuer: CN=The Orgs Name RootCA 2015,O=The Orgs name Institutions Cert. Authority,L=Location,C=TT
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
        expected_result => <<'EOF',
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 0,
        name => "invalid single pem",
        pem => <<'EOF',
Subject: CN=Some subject with 2 Points,O=A Organization,L=Some Lation,C=TT
Issuer: CN=The Orgs Name RootCA 2015,O=The Orgs name Institutions Cert. Authority,L=Location,C=TT
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdthese !?''*:;$%&/  are not allowedWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 0,
        name => "invalid multi pem",
        multiple => 1,
        pem => <<'EOF',
Subject: CN=Some subject with 2 Points,O=A Organization,L=Some Lation,C=TT
Issuer: CN=The Orgs Name RootCA 2015,O=The Orgs name Institutions Cert. Authority,L=Location,C=TT
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdthese !?''*:;$%&/  are not allowedWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
Subject: CN=Some subject with 2 Points,O=A Organization,L=Some Lation,C=TT
Issuer: CN=The Orgs Name RootCA 2015,O=The Orgs name Institutions Cert. Authority,L=Location,C=TT
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----

EOF
    },
    {
        expected_success => 1,
        name => "single as multiple pem",
        multiple => 1,
        pem => <<'EOF',
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdtheseZ2RmaXVwYWJ2aXV1YXdlYmxmamlraWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 1,
        name => "single as multiple pem",
        multiple => 1,
        pem => <<'EOF',
Subject: CN=Some subject with 2 Points,O=A Organization,L=Some Lation,C=TT
Issuer: CN=The Orgs Name RootCA 2015,O=The Orgs name Institutions Cert. Authority,L=Location,C=TT
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdtheseZ2RmaXVwYWJ2aXV1YXdlYmxmamlraWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
        expected_result => <<'EOF',
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdtheseZ2RmaXVwYWJ2aXV1YXdlYmxmamlraWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
    },
];

for my $data ($setup->@*) {
    subtest $data->{name} => sub {
        # Act
        my $check_result = PVE::Certificate::check_pem(
            $data->{pem},
            noerr => 1,
            multiple => $data->{multiple},
            label => $data->{label},
        );

        # Assert
        if ($data->{expected_success}) {
            ok($check_result, "is successful");

            my $expected_result =
                $data->{expected_result}
                ? $data->{expected_result}
                : $data->{pem};
            is(
                $check_result, $expected_result, "has correct result content",
            );
        } else {
            is($check_result, undef, "has correctly returned undef");
            eval {
                PVE::Certificate::check_pem(
                    $data->{pem},
                    multiple => $data->{multiple},
                    label => $data->{label},
                );
            };
            ok($@, "has correctly thrown an error");
        }
    }
}

done_testing();
