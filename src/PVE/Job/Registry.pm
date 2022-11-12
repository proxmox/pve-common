package PVE::Job::Registry;

use strict;
use warnings;

# The job (config) base class, normally you would use this in one of two variants:
#
# 1) base of directly in manager and handle everything there; great for stuff that isn't residing
#    outside of the manager, so that there is no cyclic dependency (forbidden!) required
#
# 2) use two (or even more) classes, one in the library (e.g., guest-common, access-control, ...)
#    basing off this module, providing the basic config implementation. Then one in pve-manager
#    (where every dependency is available) basing off the intermediate config one, that then holds
#    the implementation of the 'run` method and is used in the job manager

use base qw(PVE::SectionConfig);

my $defaultData = {
    propertyList => {
	type => { description => "Section type." },
	id => {
	    description => "The ID of the job.",
	    type => 'string',
	    format => 'pve-configid',
	    maxLength => 64,
	},
	enabled => {
	    description => "Determines if the job is enabled.",
	    type => 'boolean',
	    default => 1,
	    optional => 1,
	},
	schedule => {
	    description => "Backup schedule. The format is a subset of `systemd` calendar events.",
	    type => 'string', format => 'pve-calendar-event',
	    maxLength => 128,
	},
	comment => {
	    optional => 1,
	    type => 'string',
	    description => "Description for the Job.",
	    maxLength => 512,
	},
	'repeat-missed' => {
	    optional => 1,
	    type => 'boolean',
	    description => "If true, the job will be run as soon as possible if it was missed".
		" while the scheduler was not running.",
	    default => 0,
	},
    },
};

sub private {
    return $defaultData;
}

sub get_job {
    my ($class, $cfg, $id) = @_;

    return {
    }
}

sub parse_config {
    my ($class, $filename, $raw, $allow_unknown) = @_;

    my $cfg = $class->SUPER::parse_config($filename, $raw, $allow_unknown);

    foreach my $id (sort keys %{$cfg->{ids}}) {
	my $data = $cfg->{ids}->{$id};

	$data->{id} = $id;
	$data->{enabled}  //= 1;

	$data->{comment} = PVE::Tools::decode_text($data->{comment}) if defined($data->{comment});
   }

   return $cfg;
}

# call the plugin specific decode/encode code
sub decode_value {
    my ($class, $type, $key, $value) = @_;

    my $plugin = __PACKAGE__->lookup($type);
    return $plugin->decode_value($type, $key, $value);
}

sub encode_value {
    my ($class, $type, $key, $value) = @_;

    my $plugin = __PACKAGE__->lookup($type);
    return $plugin->encode_value($type, $key, $value);
}

sub write_config {
    my ($class, $filename, $cfg, $allow_unknown) = @_;

    for my $job (values $cfg->{ids}->%*) {
	$job->{comment} = PVE::Tools::encode_text($job->{comment}) if defined($job->{comment});
    }

    $class->SUPER::write_config($filename, $cfg, $allow_unknown);
}

sub run {
    my ($class, $cfg) = @_;

    die "not implemented"; # implement in subclass
}

1;
