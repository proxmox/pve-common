package PVE::SysFSTools;

use strict;
use warnings;

use IO::File;

use PVE::Tools qw(file_read_firstline dir_glob_foreach);

my $pcisysfs = "/sys/bus/pci";
my $domainregex = "[a-f0-9]{4,}";
my $pciregex = "($domainregex):([a-f0-9]{2}):([a-f0-9]{2})\.([a-f0-9])";

my $parse_pci_ids = sub {
    my $ids = {};

    open(my $fh, '<', "/usr/share/misc/pci.ids")
	or return $ids;

    my $curvendor;
    my $curdevice;
    while (my $line = <$fh>) {
	if ($line =~ m/^([0-9a-fA-F]{4})\s+(.*)$/) {
	    $curvendor = ($ids->{"0x$1"} = {});
	    $curvendor->{name} = $2;
	} elsif ($line =~ m/^\t([0-9a-fA-F]{4})\s+(.*)$/) {
	    $curdevice = ($curvendor->{devices}->{"0x$1"} = {});
	    $curdevice->{name} = $2;
	} elsif ($line =~ m/^\t\t([0-9a-fA-F]{4}) ([0-9a-fA-F]{4})\s+(.*)$/) {
	    $curdevice->{subs}->{"0x$1"}->{"0x$2"} = $3;
	}
    }

    return $ids;
};

my sub normalize_pci_id {
    my ($id) = @_;
    $id = "0000:$id" if $id !~ m/^${domainregex}:/;
    return $id;
};

# returns a list of pci devices
#
# filter is either a string (then it tries to match to the id)
# or a sub ref (then it adds the device if the sub returns truthy)
#
# verbose also returns iommu groups, subvendor/device and the
# human readable names from /usr/share/misc/pci.ids
#
# return format:
# [
#     {
#         id => '00:00.0',
#         vendor => '0xabab',
#         device => '0xefef',
#         class => '0x012345',
#
#         # optional
#         iommugroup => '14',
#         mdev => 1,
#         vendor_name => 'Foo Inc.',
#         device_name => 'Bar 9000AF',
#         subsystem_vendor => '0xacac',
#         subsystem_device => '0xfefe',
#         subsystem_vendor_name => 'Foo Europe GmbH',
#         subsystem_device_name => 'Bar 9001AF OC',
#     },
#     ...
# ]
#
sub lspci {
    my ($filter, $verbose) = @_;

    my $devices = [];
    my $ids = {};
    if ($verbose) {
	$ids = $parse_pci_ids->();
    }

    dir_glob_foreach("$pcisysfs/devices", $pciregex, sub {
	my ($fullid, $domain, $bus, $slot, $function) = @_;
	my $id = "$domain:$bus:$slot.$function";

	if (defined($filter) && !ref($filter) && $id !~ m/^(0000:)?\Q$filter\E/) {
	    return; # filter ids early
	}

	my $devdir = "$pcisysfs/devices/$fullid";

	my $vendor = file_read_firstline("$devdir/vendor");
	my $device = file_read_firstline("$devdir/device");
	my $class = file_read_firstline("$devdir/class");

	my $res = {
	    id => $id,
	    vendor => $vendor,
	    device => $device,
	    class => $class,
	};

	if (defined($filter) && ref($filter) eq 'CODE' && !$filter->($res)) {
	    return;
	}

	$res->{iommugroup} = -1;
	if (-e "$devdir/iommu_group") {
	    my ($iommugroup) = (readlink("$devdir/iommu_group") =~ m/\/(\d+)$/);
	    $res->{iommugroup} = int($iommugroup);
	}

	if (-d "$devdir/mdev_supported_types") {
	    $res->{mdev} = 1;
	} elsif (-d "$devdir/nvidia") {
	    # nvidia driver for kernel 6.8 or higher
	    $res->{mdev} = 1; # for api compatibility
	    $res->{nvidia} = 1;
	}

	if ($verbose) {
	    my $device_hash = $ids->{$vendor}->{devices}->{$device} // {};

	    my $sub_vendor = file_read_firstline("$devdir/subsystem_vendor");
	    my $sub_device = file_read_firstline("$devdir/subsystem_device");

	    my $vendor_name = $ids->{$vendor}->{name};
	    my $device_name = $device_hash->{name};
	    my $sub_vendor_name = $ids->{$sub_vendor}->{name};
	    my $sub_device_name = $device_hash->{subs}->{$sub_vendor}->{$sub_device};

	    $res->{vendor_name} = $vendor_name if defined($vendor_name);
	    $res->{device_name} = $device_name if defined($device_name);
	    $res->{subsystem_vendor} = $sub_vendor if defined($sub_vendor);
	    $res->{subsystem_device} = $sub_device if defined($sub_device);
	    $res->{subsystem_vendor_name} = $sub_vendor_name if defined($sub_vendor_name);
	    $res->{subsystem_device_name} = $sub_device_name if defined($sub_device_name);
	}

	push @$devices, $res;
    });

    # Entries should be sorted by ids
    $devices = [ sort { $a->{id} cmp $b->{id} } @$devices ];

    return $devices;
}

#
# return format:
# [
#     {
#         type => 'FooType_1',
#         description => "a longer description with custom format\nand newlines",
#         available => 5,
#     },
#     ...
# ]
#
sub get_mdev_types {
    my ($id) = @_;

    $id = normalize_pci_id($id);

    my $types = [];

    my $dev_path = "$pcisysfs/devices/$id";
    my $mdev_path = "$dev_path/mdev_supported_types";
    my $nvidia_path = "$dev_path/nvidia/creatable_vgpu_types";
    if (-d $mdev_path) {
	dir_glob_foreach($mdev_path, '[^\.].*', sub {
	    my ($type) = @_;

	    my $type_path = "$mdev_path/$type";

	    my $available = int(file_read_firstline("$type_path/available_instances"));
	    my $description = PVE::Tools::file_get_contents("$type_path/description");

	    my $entry = {
		type => $type,
		description => $description,
		available => $available,
	    };

	    my $name = file_read_firstline("$type_path/name");
	    $entry->{name} = $name if defined($name);

	    push @$types, $entry;
	});
    } elsif (-f $nvidia_path) {
	my $creatable = PVE::Tools::file_get_contents($nvidia_path);
	for my $line (split("\n", $creatable)) {
	    next if $line =~ m/^ID/; # header
	    next if $line !~ m/^(.*?)\s*:\s*(.*)$/;
	    my $id = $1;
	    my $name = $2;

	    push $types->@*, {
		type => "nvidia-$id", # backwards compatibility
		description => "", # TODO, read from xml/nvidia-smi ?
		available => 1,
		name  => $name,
	    }
	}
    }

    return $types;
}

sub check_iommu_support{
    # we have IOMMU support if /sys/class/iommu/ is populated
    return PVE::Tools::dir_glob_regex('/sys/class/iommu/', "[^\.].*");
}

# writes $buf into $filename, on success returns 1, on error returns 0 and warns
# if $allow_existing is set, an EEXIST error will be handled as success
sub file_write {
    my ($filename, $buf, $allow_existing) = @_;

    my $fh = IO::File->new($filename, "w");
    return undef if !$fh;

    my $res = syswrite($fh, $buf);
    my ($syserr, %syserr) = ($!, %!); # only relevant if $res is undefined
    $fh->close();

    if (defined($res)) {
	return 1;
    } elsif ($syserr) {
	return 1 if $allow_existing && $syserr{EEXIST};
	warn "error writing '$buf' to '$filename': $syserr\n";
    }

    return 0;
}

sub pci_device_info {
    my ($name, $verbose) = @_;

    my $res;

    return undef if $name !~ m/^${pciregex}$/;
    my ($domain, $bus, $slot, $func) = ($1, $2, $3, $4);

    my $devdir = "$pcisysfs/devices/$name";

    my $irq = file_read_firstline("$devdir/irq");
    return undef if !defined($irq) || $irq !~ m/^\d+$/;

    my $vendor = file_read_firstline("$devdir/vendor");
    return undef if !defined($vendor) || $vendor !~ s/^0x//;

    my $product = file_read_firstline("$devdir/device");
    return undef if !defined($product) || $product !~ s/^0x//;

    $res = {
	name => $name,
	vendor => $vendor,
	device => $product,
	domain => $domain,
	bus => $bus,
	slot => $slot,
	func => $func,
	irq => $irq,
	has_fl_reset => -f "$pcisysfs/devices/$name/reset" || 0,
    };

    if ($verbose) {
	my $sub_vendor = file_read_firstline("$devdir/subsystem_vendor");
	$sub_vendor =~ s/^0x// if defined($sub_vendor);
	my $sub_device = file_read_firstline("$devdir/subsystem_device");
	$sub_device =~ s/^0x// if defined($sub_device);

	$res->{subsystem_vendor} = $sub_vendor if defined($sub_vendor);
	$res->{subsystem_device} = $sub_device if defined($sub_device);

	if (-e "$devdir/iommu_group") {
	    my ($iommugroup) = (readlink("$devdir/iommu_group") =~ m/\/(\d+)$/);
	    $res->{iommugroup} = int($iommugroup);
	}

	if (-d "$devdir/mdev_supported_types") {
	    $res->{mdev} = 1;
	}
    }

    return $res;
}

sub pci_dev_reset {
    my ($dev) = @_;

    my $name = $dev->{name};

    my $fn = "$pcisysfs/devices/$name/reset";

    return file_write($fn, "1");
}

sub pci_dev_bind_to_vfio {
    my ($dev) = @_;

    my $name = $dev->{name};

    my $vfio_basedir = "$pcisysfs/drivers/vfio-pci";

    if (!-d $vfio_basedir) {
	system("/sbin/modprobe vfio-pci >/dev/null 2>/dev/null");
    }
    die "Cannot find vfio-pci module!\n" if !-d $vfio_basedir;

    my $testdir = "$vfio_basedir/$name";
    return 1 if -d $testdir;

    my $data = "$dev->{vendor} $dev->{device}";
    # allow EEXIST for multiple devices with the same vendor/modelid
    return undef if !file_write("$vfio_basedir/new_id", $data, 1);

    my $fn = "$pcisysfs/devices/$name/driver/unbind";
    if (!file_write($fn, $name)) {
	return undef if -f $fn;
    }

    $fn = "$vfio_basedir/bind";
    if (! -d $testdir) {
	return undef if !file_write($fn, $name);
    }

    return -d $testdir;
}

sub pci_dev_group_bind_to_vfio {
    my ($pciid) = @_;

    my $vfio_basedir = "$pcisysfs/drivers/vfio-pci";

    if (!-d $vfio_basedir) {
	system("/sbin/modprobe vfio-pci >/dev/null 2>/dev/null");
    }
    die "Cannot find vfio-pci module!\n" if !-d $vfio_basedir;

    $pciid = normalize_pci_id($pciid);

    # get IOMMU group devices
    opendir(my $D, "$pcisysfs/devices/$pciid/iommu_group/devices/") || die "Cannot open iommu_group: $!\n";
    my @devs = grep /^${domainregex}:/, readdir($D);
    closedir($D);

    foreach my $pciid (@devs) {
	$pciid =~ m/^([:\.0-9a-f]+)$/ or die "PCI ID $pciid not valid!\n";

	# PCI bridges, switches or root-ports aren't supported and all have a pci_bus dir we can test
	next if (-e "$pcisysfs/devices/$pciid/pci_bus");

	my $info = pci_device_info($1);
	pci_dev_bind_to_vfio($info) || die "Cannot bind $pciid to vfio\n";
    }

    return 1;
}

sub pci_create_mdev_device {
    my ($pciid, $uuid, $type) = @_;

    $pciid = normalize_pci_id($pciid);

    my $basedir = "$pcisysfs/devices/$pciid";
    my $mdev_dir = "$basedir/mdev_supported_types";

    die "pci device '$pciid' does not support mediated devices \n"
	if !-d $mdev_dir;

    die "pci device '$pciid' has no type '$type'\n"
	if !-d "$mdev_dir/$type";

    if (-d "$basedir/$uuid") {
	# it already exists, checking type
	my $typelink = readlink("$basedir/$uuid/mdev_type");
	my ($existingtype) = $typelink =~ m|/([^/]+)$|;
	die "mdev instance '$uuid' already exits, but type is not '$type'\n"
	    if $type ne $existingtype;

	# instance exists, so use it but warn the user
	warn "mdev instance '$uuid' already existed, using it.\n";
	return undef;
    }

    my $instances = file_read_firstline("$mdev_dir/$type/available_instances");
    my ($avail) = $instances =~ m/^(\d+)$/;
    die "pci device '$pciid' has no available instances of '$type'\n"
	if $avail < 1;

    die "could not create 'type' for pci devices '$pciid'\n"
	if !file_write("$mdev_dir/$type/create", $uuid);

    return undef;
}

# encode the hostpci index and vmid into the uuid
sub generate_mdev_uuid {
    my ($vmid, $index) = @_;

    my $string = sprintf("%08d-0000-0000-0000-%012d", $index, $vmid);

    return $string;
}

# idea is from usbutils package (/usr/bin/usb-devices) script
sub __scan_usb_device {
    my ($res, $devpath, $parent, $level) = @_;

    return if ! -d $devpath;
    return if $level && $devpath !~ m/^.*[-.](\d+)$/;
    my $port = $level ? int($1 - 1) : 0;

    my $busnum = int(file_read_firstline("$devpath/busnum"));
    my $devnum = int(file_read_firstline("$devpath/devnum"));

    my $d = {
	port => $port,
	level => $level,
	busnum => $busnum,
	devnum => $devnum,
	speed => file_read_firstline("$devpath/speed"),
	class => hex(file_read_firstline("$devpath/bDeviceClass")),
	vendid => file_read_firstline("$devpath/idVendor"),
	prodid => file_read_firstline("$devpath/idProduct"),
    };

    if ($level) {
	my $usbpath = $devpath;
	$usbpath =~ s|^.*/\d+\-||;
	$d->{usbpath} = $usbpath;
    }

    my $product = file_read_firstline("$devpath/product");
    $d->{product} = $product if $product;

    my $manu = file_read_firstline("$devpath/manufacturer");
    $d->{manufacturer} = $manu if $manu;

    my $serial => file_read_firstline("$devpath/serial");
    $d->{serial} = $serial if $serial;

    push @$res, $d;

    foreach my $subdev (<$devpath/$busnum-*>) {
	next if $subdev !~ m|/$busnum-[0-9]+(\.[0-9]+)*$|;
	__scan_usb_device($res, $subdev, $devnum, $level + 1);
    }

};

sub scan_usb {

    my $devlist = [];

    foreach my $device (</sys/bus/usb/devices/usb*>) {
	__scan_usb_device($devlist, $device, 0, 0);
    }

    return $devlist;
}

1;
