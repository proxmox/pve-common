package PVE::Exception;

# a way to add more information to exceptions (see man perlfunc (die))
# use PVE::Exception qw(raise);
# raise ("my error message", code => 400, errors => { param1 => "err1", ...} );

use strict;
use warnings;
use vars qw(@ISA @EXPORT_OK);
require Exporter;
use Storable qw(dclone);       
use HTTP::Status qw(:constants);

@ISA = qw(Exporter);

use overload '""' => sub {local $@; shift->stringify};
use overload 'cmp' => sub {
    my ($a, $b) = @_;
    local $@;  
    return "$a" cmp "$b"; # compare as string
};

@EXPORT_OK = qw(raise raise_param_exc raise_perm_exc);

sub new {
    my ($class, $msg, %param) = @_;

    $class = ref($class) || $class;

    my $self = {
	msg => $msg,
    };

    foreach my $p (keys %param) {
	next if defined($self->{$p}); 
	my $v = $param{$p};
	$self->{$p} = ref($v) ? dclone($v) : $v;
    }

    return bless $self;
}

sub raise {

    my $exc = PVE::Exception->new(@_);
    
    my ($pkg, $filename, $line) = caller;

    $exc->{filename} = $filename;
    $exc->{line} = $line;

    die $exc;
}

sub raise_perm_exc {
    my ($what) = @_;

    my $param = { code => HTTP_FORBIDDEN };

    my $msg = "Permission check failed";
    
    $msg .= " ($what)" if $what;

    my $exc = PVE::Exception->new("$msg\n", %$param);
    
    my ($pkg, $filename, $line) = caller;

    $exc->{filename} = $filename;
    $exc->{line} = $line;

    die $exc;
}

sub is_param_exc {
    my ($self) = @_;

    return $self->{code} && $self->{code} eq HTTP_BAD_REQUEST;
}

sub raise_param_exc {
    my ($errors, $usage) = @_;

    my $param = {
	 code => HTTP_BAD_REQUEST,
	 errors => $errors,
    };

    $param->{usage} = $usage if $usage;

    my $exc = PVE::Exception->new("Parameter verification failed.\n", %$param);
    
    my ($pkg, $filename, $line) = caller;

    $exc->{filename} = $filename;
    $exc->{line} = $line;

    die $exc;
}

sub stringify {
    my $self = shift;
    
    my $msg = $self->{code} ? "$self->{code} $self->{msg}" : $self->{msg};

    if ($msg !~ m/\n$/) {

	if ($self->{filename} && $self->{line}) {
	    $msg .= " at $self->{filename} line $self->{line}";
	}

	$msg .= "\n";
    }

    if ($self->{errors}) {
	foreach my $e (keys %{$self->{errors}}) {
	    $msg .= "$e: $self->{errors}->{$e}\n";
	}
    }

    if ($self->{propagate}) {
	foreach my $pi (@{$self->{propagate}}) {
	    $msg .= "\t...propagated at $pi->[0] line $pi->[1]\n";
	}
    }

    if ($self->{usage}) {
	$msg .= $self->{usage};
	$msg .= "\n" if $msg !~ m/\n$/;
    }

    return $msg;
}

sub PROPAGATE {
    my ($self, $file, $line) = @_;

    push @{$self->{propagate}}, [$file, $line]; 

    return $self;
}

1;
