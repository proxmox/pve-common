#!/usr/bin/perl
# Tests the PVE::Certificate::split_pem function for
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
        name => "single pem",
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
        name => "no extra text pem",
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

        expected_result => [
            <<'EOF',
-----BEGIN CERTIFICATE-----
12JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF

            <<'EOF',
-----BEGIN CERTIFICATE-----
22JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF

            <<'EOF',
-----BEGIN CERTIFICATE-----
32JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF

            <<'EOF',
-----BEGIN CERTIFICATE-----
42JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
        ],
    },
    {
        expected_success => 1,
        name => "leading and interleaved text pem",
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
Subject: CN=Org Root CA
Issuer: CN=Org Root CA
-----BEGIN CERTIFICATE-----
3WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF

        expected_result => [
            <<'EOF',
Subject: CN=some.test.content
Issuer: CN=Org Issuing CA 3
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF

            <<'EOF',
Subject: CN=Org Issuing CA 3
Issuer: CN=Org Root CA
-----BEGIN CERTIFICATE-----
2WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF

            <<'EOF',
Subject: CN=Org Root CA
Issuer: CN=Org Root CA
-----BEGIN CERTIFICATE-----
3WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
        ],
    },
    {
        expected_success => 1,
        name => "massive glob pem",
        pem => <<'EOF',
Subject: CN=some.test.content
Issuer: CN=Org Issuing CA 3
-----BEGIN CERTIFICATE-----
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
Subject: CN=Org Issuing CA 3
Issuer: CN=Org Root CA
-----BEGIN CERTIFICATE-----
2WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
Subject: CN=Org Root CA
Issuer: CN=Org Root CA
-----BEGIN CERTIFICATE-----
3WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
    },
    {
        expected_success => 1,
        name => "no beginning pem",
        pem => <<'EOF',
Subject: CN=some.test.content
Issuer: CN=Org Issuing CA 3
2WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
Subject: CN=Org Root CA
Issuer: CN=Org Root CA
3WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF

        expected_result => [
            <<'EOF',
Subject: CN=some.test.content
Issuer: CN=Org Issuing CA 3
2WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF

            <<'EOF',
Subject: CN=Org Root CA
Issuer: CN=Org Root CA
3WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
        ],

    },
    {
        expected_success => 0,
        name => "not a pem pem",
        pem => <<'EOF',
Subject: CN=some.test.content
Issuer: CN=Org Issuing CA 3
1WtzZGhmbGtqYXNoZ2RmaXVwYWJ2aXV1YXdlYmxmamlraGFzZGtmYWlzdXBkdW5i
dmFpdXdlYmdmw7ZrYWpkc2JoZmdpYXNkbmJpZnVhYmdzaWprZmdyYXNkaHJmaW9h
dXNkbmF1c2JmZ3ZramFzZGJma2phc2RibmZpanVhIHNkb3ZuYmF3b3VlYmZnb2F3
c2JlZ2tseTxzZWl2IGF3ZWlidm4=
Subject: CN=Org Issuing CA 3
Issuer: CN=Org Root CA
EOF
    },
    {
        expected_success => 1,
        name => "following text pem",
        pem => <<'EOF',
-----BEGIN CERTIFICATE-----
32JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
42JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
some more text that we would like to remove
EOF

        expected_result => [
            <<'EOF',
-----BEGIN CERTIFICATE-----
32JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF

            <<'EOF',
-----BEGIN CERTIFICATE-----
42JlZ2tseTxzZWl2IGF3ZWlidm4=
-----END CERTIFICATE-----
EOF
        ],
    },
];

for my $data ($setup->@*) {
    subtest $data->{name} => sub {
        # Act
        my @split_result = PVE::Certificate::split_pem(
            $data->{pem}, label => $data->{label},
        );

        # Assert
        if ($data->{expected_success}) {
            ok(@split_result, "is successful");
            my $expected_result =
                $data->{expected_result}
                ? $data->{expected_result}
                : [$data->{pem}];

            is_deeply(
                \@split_result, \@$expected_result, "has correct split output",
            );
        } else {
            is_deeply(\@split_result, [], "has correctly returned empty");
        }
    }
}

done_testing();
