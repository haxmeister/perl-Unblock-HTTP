package Unblock::HTTP;

use strict;
use warnings;

our $VERSION = '0.01';

1;

__END__

=head1 NAME

Unblock::HTTP - One application interface for HTTP/1, HTTP/2, and HTTP/3

=head1 SYNOPSIS

    use Unblock::HTTP::Server;

    my $http = Unblock::HTTP::Server->new(
        transport  => $stream,
        alpn       => $negotiated_alpn,
        on_request => sub {
            my ($tx, $request) = @_;
            $tx->respond(status => 200, body => "hello\n");
        },
    );

    $http->input($bytes);

=head1 DESCRIPTION

This is the event-loop-neutral application layer over Unblock::HTTP1,
Unblock::HTTP2, and Unblock::HTTP3. It uses their common Client, Server,
and Transaction vocabulary while leaving protocol parsing to the engines.

The first version selects a protocol from the supplied ALPN result or an
explicit C<protocol> option. An unnegotiated TCP connection defaults to
HTTP/1.1. HTTP/3 uses an existing Net::QUIC connection.

It does not create sockets, negotiate TLS, or require any particular event
loop. The optional L<Unblock::HTTP::QUIC> class manages HTTP/3 sessions
over L<Net::QUIC::Driver>. See L<Unblock::HTTP::Integration>.

=head1 CLASSES

=over 4

=item L<Unblock::HTTP::Client>

One outgoing HTTP connection.

=item L<Unblock::HTTP::Server>

One incoming HTTP connection.

=item L<Unblock::HTTP::Adapter::LinuxEvent>

Optional reusable Linux::Event server Stream.

=item L<Unblock::HTTP::QUIC>

HTTP/3 session management over Net::QUIC.

=item L<Unblock::HTTP::Integration>

How to connect the unified interface to a framework.

=back

=head1 LICENSE

MIT License.

=cut
