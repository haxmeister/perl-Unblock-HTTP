package Unblock::HTTP::Adapter::LinuxEvent;

use v5.36;
use strict;
use warnings;
use parent 'Linux::Event::IO::Sock::Stream';
use Scalar::Util qw(weaken);

our $VERSION = '0.01';

sub http { $_[0]{unblock_http} }

# Override this in a subclass for a cleartext HTTP/2 prior-knowledge port.
# For TLS, the adapter uses the ALPN chosen by Linux::Event instead.
sub http_protocol { undef }

sub on_ready ($self) {
    require Unblock::HTTP::Server;

    my $stream = $self;
    weaken($stream);

    my $protocol = $self->http_protocol;
    my %select = defined($protocol)
        ? (protocol => $protocol)
        : (alpn => $self->selected_alpn);

    $self->{unblock_http} = Unblock::HTTP::Server->new(
        transport  => $self,
        %select,
        on_request => sub ($tx, $request) {
            $stream->on_http_request($tx, $request) if $stream;
        },
    );
    $self->{unblock_backend} = $self->{unblock_http}->backend;
}

sub on_http_request ($self, $tx, $request) {
    die "on_http_request() must be implemented by a subclass\n";
}

sub on_data ($self, $bytes) {
    $self->{unblock_backend}->input($bytes);
}

sub on_eof ($self) {
    my $http = $self->{unblock_backend};
    $http->input_eof if $http && $http->want_read;
}

sub on_error ($self, $error) {
    my $http = $self->{unblock_backend};
    $http->transport_error("$error") if $http;
}

sub on_drain ($self) {
    my $http = $self->{unblock_backend};
    $http->resume_output if $http;
}

sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die "Linux::Event stream closed during HTTP output\n" if $self->is_closed;
    return $ready;
}

sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

1;

__END__

=head1 NAME

Unblock::HTTP::Adapter::LinuxEvent - Host Unblock HTTP/1 or HTTP/2 in a Linux::Event Stream

=head1 SYNOPSIS

    use v5.36;
    use Linux::Event::Loop;
    use Linux::Event::IO::Sock::Listener;
    use Unblock::HTTP::Adapter::LinuxEvent;

    package MyHTTPStream;
    use parent 'Unblock::HTTP::Adapter::LinuxEvent';

    sub on_http_request ($self, $tx, $request) {
        $tx->respond(status => 200, body => "hello\n");
    }

    package main;

    my $loop = Linux::Event::Loop->new;
    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop => $loop, host => '127.0.0.1', port => 8080,
        stream => { class => 'MyHTTPStream' },
    );
    $loop->run;

=head1 DESCRIPTION

This optional adapter is a normal Linux::Event Stream subclass. A listener
accepts it as its stream class. It attaches Unblock::HTTP on readiness,
forwards network reads and EOF, and handles output and backpressure. You
only implement C<on_http_request> in an application subclass.

TLS uses the framework's negotiated C<selected_alpn> after the handshake.
A plain connection defaults to HTTP/1.1. To use prior-knowledge cleartext
HTTP/2, override C<http_protocol> to return C<h2>.

The hot read path calls the underlying engine directly, avoiding a second
per-chunk dispatcher call. The C<http> method returns the unified connection
after readiness. The
framework owns the Stream and socket. The Unblock engine remains a separate
composed object, not an inherited HTTP implementation.

Linux::Event is not a required dependency for normal Unblock::HTTP users.
Loading this optional adapter does require Linux::Event 0.117 or later.

=head1 LICENSE

MIT License.

=cut
