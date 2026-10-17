package Unblock::HTTP::Integration;

use strict;
use warnings;

our $VERSION = '0.01';

1;

__END__

=head1 NAME

Unblock::HTTP::Integration - Attach framework transports to HTTP engines

=head1 IMPLEMENTATION STATUS

This feature-branch checkpoint supplies reusable Server policy and direct
engine attachment. It retains engine callback timing. Buffered application
callbacks, automatic WebSocket transitions, client pooling and transport
factories are later stages. See docs/IMPLEMENTATION.md in the repository.

=head1 TCP AND TLS SERVERS

Create one L<Unblock::HTTP::Server> definition for the service. Configure the
framework listener's TLS ALPN choices using C<$server-E<gt>alpn_protocols>.
The framework owns listeners, sockets, TLS, timers, and network queues.

For each accepted connection, retain the actual returned engine:

    $self->{http} = $server->attach_stream(
        transport => $self,
        alpn => $negotiated_alpn,
    );

The adapter passes decrypted bytes directly to that engine. There is no
Server-definition call on the read path:

    $self->{http}->input($bytes);
    $self->{http}->input_eof;
    $self->{http}->transport_error($error);

Call C<input_eof> once when the peer's read side ends. The framework must not
continue feeding a closed engine. Constructor and attachment errors belong
to adapter setup; handle them before accepting further traffic.

For cleartext H2 prior knowledge, use C<protocol =E<gt> 'h2'> instead of
C<alpn>. Missing or empty ALPN selects H1 only when enabled. Unknown or
disallowed negotiation results fail. The selector does not sniff input bytes.

=head1 OUTPUT CONTRACT

The attached transport implements:

    unblock_send($bytes)
    unblock_finish()
    unblock_abort($reason)

C<unblock_send> accepts the entire buffer or throws. True or undef means it
can accept more output. A defined false value means it accepted every byte
but is congested. It must retain any bytes not yet written by the socket.
False never means partial acceptance, and the engine must not resend the
accepted buffer. When capacity returns, call:

    $self->{http}->resume_output;

C<unblock_finish> asks the framework to flush accepted output and then finish
normally. C<unblock_abort> reports failure and requests immediate teardown.
Do not implement another independent network queue in Unblock::HTTP.

The engine holds the transport weakly. The framework must retain both the
transport and its engine. The reusable Server does not retain attached
engines. Callbacks shared by a Server definition should not capture every
connection or create ownership cycles.

=head1 HTTP/3

Use a ready QUIC connection already negotiated for HTTP/3:

    my $engine = $server->attach_quic(connection => $ready_h3_connection);

The returned HTTP3 Server is already started. Keep it alive while the QUIC
connection is active. This attachment method does not negotiate ALPN; the
caller supplies an H3 connection. UDP packets never go to HTTP C<input>.

L<Unblock::HTTP::QUIC> can manage readiness and engine lifetime for all
connections on a server Driver:

    my $endpoint = Unblock::HTTP::QUIC->server(
        server => $server,
        certificate_file => $cert,
        private_key_file => $key,
        send => $send_datagram,
        set_timeout => $replace_timer,
    );
    $endpoint->start;

Forward UDP receive events to C<receive>, timer expiry to C<timeout>, and
recovered UDP capacity to C<writable>. Net::QUIC::Driver determines the next
timeout in seconds; the framework replaces its timer accordingly. The manager
sets H3 ALPN and uses the supplied reusable Server definition without overriding
its callbacks or policy. C<on_ready> receives the real HTTP3 Server engine.

=head1 EXISTING CLIENT

The current Client is still a single-connection object. Construct it with
C<transport> and C<alpn>, then use its request and input/output methods.
A future stage replaces this API with destination management and a shared
framework connection factory. Do not infer pooling or automatic connection
creation from the new Server API.

=head1 OPTIONAL LINUX::EVENT ADAPTER

L<Unblock::HTTP::Adapter::LinuxEvent> is an optional Stream subclass.
Override C<http_server()> to return the shared Server definition. It attaches
on readiness and feeds input directly to the selected engine. Application
callbacks belong to the definition, not to each Stream subclass.

See examples/linux-event-server.pl and examples/linux-event-quic-server.pl.
This adapter is a reference integration; it is not loaded by core classes.

=head1 REMAINING CONTRACT WORK

The final application API requires transaction receive-mode selection,
terminal notification, per-stream pause/resume, and protocol transition hooks.
The existing whole-buffer transport contract remains in force. Hard buffer
limits, oversized writes, borrowed-buffer ownership across transitions, and
all terminal paths still need cross-engine verification.

=head1 LICENSE

MIT License.

=cut
