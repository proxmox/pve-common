package PVE::SysFSTools;

use strict;
use warnings;

use IO::File;

use PVE::Tools qw(file_read_firstline dir_glob_foreach);

my $pcisysfs = "/sys/bus/pci";
my $pciregex = "([a-f0-9]{4}):([a-f0-9]{2}):([a-f0-9]{2})\.([a-f0-9])";

sub lspci {
    my ($id_filter) = @_;

    my $devices = {};

    dir_glob_foreach("$pcisysfs/devices", $pciregex, sub {
            my (undef, undef, $bus, $slot, $function) = @_;

	    my $id = "$bus:$slot";
	    return if defined($id_filter) && $id_filter ne $id;

	    push @{$devices->{$id}}, { id => $id, function => $function };
    });

    # Entries should be sorted by functions.
    foreach my $id (keys %$devices) {
	my $dev = $devices->{$id};
	$devices->{$id} = [ sort { $a->{function} <=> $b->{function} } @$dev ];
    }

    return $devices;
}

sub get_mdev_types {
    my ($id) = @_;

    my $fullid = $id;
    if ($id !~ m/^[0-9a-fA-f]{4}:/) {
	$fullid = "0000:$id";
    }

    my $types = [];

    my $mdev_path = "$pcisysfs/devices/$fullid/mdev_supported_types";
    if (!-d $mdev_path) {
	return $types;
    }

    dir_glob_foreach($mdev_path, '[^\.].*', sub {
	my ($type) = @_;

	my $type_path = "$mdev_path/$type";

	my $available = int(file_read_firstline("$type_path/available_instances"));
	my $description = PVE::Tools::file_get_contents("$type_path/description");

	push @$types, {
	    type => $type,
	    description => $description,
	    available => $available,
	};
    });

    return $types;
}

sub check_iommu_support{
    # we have IOMMU support if /sys/class/iommu/ is populated
    return PVE::Tools::dir_glob_regex('/sys/class/iommu/', "[^\.].*");
}

sub file_write {
    my ($filename, $buf) = @_;

    my $fh = IO::File->new($filename, "w");
    return undef if !$fh;

    my $res = print $fh $buf;

    $fh->close();

    return $res;
}

sub pci_device_info {
    my ($name) = @_;

    my $res;

    return undef if $name !~ m/^${pciregex}$/;
    my ($domain, $bus, $slot, $func) = ($1, $2, $3, $4);

    my $irq = file_read_firstline("$pcisysfs/devices/$name/irq");
    return undef if !defined($irq) || $irq !~ m/^\d+$/;

    my $vendor = file_read_firstline("$pcisysfs/devices/$name/vendor");
    return undef if !defined($vendor) || $vendor !~ s/^0x//;

    my $product = file_read_firstline("$pcisysfs/devices/$name/device");
    return undef if !defined($product) || $product !~ s/^0x//;

    $res = {
	name => $name,
	vendor => $vendor,
	product => $product,
	domain => $domain,
	bus => $bus,
	slot => $slot,
	func => $func,
	irq => $irq,
	has_fl_reset => -f "$pcisysfs/devices/$name/reset" || 0,
    };

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

    my $data = "$dev->{vendor} $dev->{product}";
    return undef if !file_write("$vfio_basedir/new_id", $data);

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

    # get IOMMU group devices
    opendir(my $D, "$pcisysfs/devices/0000:$pciid/iommu_group/devices/") || die "Cannot open iommu_group: $!\n";
      my @devs = grep /^0000:/, readdir($D);
    closedir($D);

    foreach my $pciid (@devs) {
	$pciid =~ m/^([:\.\da-f]+)$/ or die "PCI ID $pciid not valid!\n";

        # pci bridges, switches or root ports are not supported
        # they have a pci_bus subdirectory so skip them
        next if (-e "$pcisysfs/devices/$pciid/pci_bus");

	my $info = pci_device_info($1);
	pci_dev_bind_to_vfio($info) || die "Cannot bind $pciid to vfio\n";
    }

    return 1;
}

sub pci_create_mdev_device {
    my ($pciid, $uuid, $type) = @_;

    my $basedir = "$pcisysfs/devices/0000:$pciid";
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

sub pci_cleanup_mdev_device {
    my ($pciid, $uuid) = @_;

    my $basedir = "$pcisysfs/devices/0000:$pciid/$uuid";

    if (! -e $basedir) {
	return 1; # no cleanup necessary if it does not exist
    }

    return file_write("$basedir/remove", "1");
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
