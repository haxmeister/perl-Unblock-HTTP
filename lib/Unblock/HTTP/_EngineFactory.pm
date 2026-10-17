package Unblock::HTTP::_EngineFactory;

use strict;
use warnings;
use Carp qw(croak);

my %ENGINE = (
    'http/1.1' => 'Unblock::HTTP1',
    h2 => 'Unblock::HTTP2',
    h3 => 'Unblock::HTTP3',
);

sub create {
    my ($class, $role, $protocol, %options) = @_;
    croak 'engine role must be Client or Server'
        unless defined($role) && ($role eq 'Client' || $role eq 'Server');
    croak 'protocol must be a scalar' unless defined($protocol) && !ref($protocol);
    croak "unsupported HTTP protocol '$protocol'" unless exists $ENGINE{$protocol};
    my $module = $ENGINE{$protocol} . '::' . $role;
    (my $file = $module) =~ s{::}{/}g;
    require "$file.pm";
    return $module->new(%options);
}

1;
