#!/usr/bin/perl

# Basic tests for the File module

use v5.36;

use lib '../src';

use PVE::File;

use Encode;
use File::Path qw(remove_tree);
use Test::More;

# TODO:
# - better structure the read-write tests (array of hash or the like)
# - add coverage for other parameter and methods
# - more tests

my $test_dir = "/tmp/test-file-$$";
mkdir($test_dir) or $!{EEXIST} or die "failed to create test-dir - $!\n";

my $first_line = "Et repudiandae deleniti dolorem harum deleniti enim.";
my $last_line = "Reprehenderit minus ratione quia magnam.";
my $two_lines = "$first_line\n$last_line\n";

# simple write-read-compare test

PVE::File::file_set_contents("$test_dir/two_lines", $two_lines);
my $two_lines_written = PVE::File::file_get_contents("$test_dir/two_lines");
is_deeply($two_lines, $two_lines_written, "simple write-read-compare test with two lines");

my $first_line_written = PVE::File::file_read_first_line("$test_dir/two_lines");
is_deeply($first_line, $first_line_written, "read only first line");

my $last_line_written = PVE::File::file_read_last_line("$test_dir/two_lines");
is_deeply($last_line, $last_line_written, "read only first line");


# try $force_utf8
my $wide_chars;
{
    use utf8;
    $wide_chars = "ÄÖÜ™🚀🚀\n";
}
my $wide_chars_encoded = Encode::encode('utf-8', $wide_chars);

PVE::File::file_set_contents("$test_dir/wide_chars", $wide_chars, undef, 1);
my $wide_chars_written = PVE::File::file_get_contents("$test_dir/wide_chars");
is_deeply(
    $wide_chars_encoded,
    $wide_chars_written,
    "simple write-read-compare test with wide-characters",
);

done_testing();

remove_tree($test_dir);
