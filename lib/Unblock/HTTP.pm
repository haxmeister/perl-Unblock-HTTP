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

    my $server = Unblock::HTTP::Server->new(
        http1 => {},
        http2 => {},
        on_request => sub {
            my ($tx, $request) = @_;
            $tx->respond(status => 200, body => "hello\n");
        },
    );

    my $engine = $server->attach_stream(
        transport => $stream,
        alpn => $negotiated_alpn,
    );
    $engine->input($bytes);

=head1 DESCRIPTION

This is the event-loop-neutral application layer over Unblock::HTTP1,
Unblock::HTTP2, and Unblock::HTTP3. It uses their common Client, Server,
and Transaction vocabulary while leaving protocol parsing to the engines.

The attachment API selects a protocol from the supplied ALPN result or an
explicit C<protocol> option. An unnegotiated TCP connection selects
HTTP/1.1 only when enabled. HTTP/3 uses an existing Net::QUIC connection.

It does not create sockets, negotiate TLS, or require any particular event
loop. The optional L<Unblock::HTTP::QUIC> class manages HTTP/3 sessions
over L<Net::QUIC::Driver>. See L<Unblock::HTTP::Integration>.

=head1 IMPLEMENTATION STATUS

This feature branch implements reusable Server attachment, bounded buffered
requests, and per-transaction streaming. It requires the coordinated engine
receive/lifecycle branches. WebSocket transitions, client pooling and transport
factories remain planned. See docs/IMPLEMENTATION.md.

=head1 CLASSES

=over 4

=item L<Unblock::HTTP::Client>

Currently one outgoing HTTP connection; the multi-destination API is planned.

=item L<Unblock::HTTP::Server>

One reusable server definition shared by incoming connections.

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
