package Unblock::HTTP::Integration;

use strict;
use warnings;

our $VERSION = '0.01';

1;

__END__

=head1 NAME

Unblock::HTTP::Integration - Attach framework transports to HTTP engines

=head1 IMPLEMENTATION STATUS

This feature branch supplies reusable Server policy and direct engine
attachment, with bounded buffered or streamed Server callbacks. It requires
the coordinated engine feature branches. Automatic WebSocket transitions,
shared Client factories and bounded pooling are now in progress. Validated
Cross-host Alt-Svc, post-dispatch retries and WebSocket transitions remain
later stages. Authenticated same-host Alt-Svc and unsent fallback are available.
See docs/IMPLEMENTATION.md in the repository.

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

=head1 SHARED CLIENT FACTORIES

The shared Client requires framework callbacks for connection establishment:

    my $client = Unblock::HTTP::Client->new(
        http1 => {}, http2 => {}, http3 => {},
        connect_stream => sub {
            my ($origin, $alpn_choices, $ready) = @_;
            # Use the framework to establish TCP/TLS.
            # In its connection callback:
            # my $engine = $ready->(
            #     transport => $framework_stream, alpn => $negotiated,
            # );
            # $framework_stream->{http_engine} = $engine;
        },
        connect_quic => sub {
            my ($origin, $ready) = @_;
            # Establish QUIC with the framework/Net::QUIC::Driver.
            # my $engine = $ready->(connection => $ready_quic);
        },
        defer => sub {
            my ($callback) = @_;
            # Schedule for a LATER event-loop turn, never inline.
        },
    );

The ready callback returns the actual H1, H2, or H3 Client engine after
successful attachment, so the framework can retain it. Every new
connect_stream invocation requires its OWN connected byte transport;
it must not attach a second HTTP engine to an already-owned socket. Feed TCP bytes,
EOF, errors and recovered output capacity directly to that engine. For
HTTP/3, preserve QUIC Driver UDP and timer operation and let HTTP/3 own
its stream callbacks. The pooled Client is not a byte-path forwarding object.

The TCP factory may report C<verified_origin =E<gt> 1> ONLY after
successfully validating the HTTPS TLS certificate against the original
origin hostname. This enables learning Alt-Svc from that connection.
The QUIC factory receives C<alternative_host> and C<alternative_port>
when an advertised alternative is selected, while retaining the original
origin authority and host. It MUST authenticate the QUIC peer for the
original HTTPS origin and report C<verified_origin =E<gt> 1> for the
request to be dispatched. A missing attestation rejects that alternative.

A Client may enable C<idle_timeout> with its optional framework timer
factory and C<release_connection> hook. On the first completely idle
period after the last active transaction (and without waiting queued
requests), a timer runs. Reuse cancels the timer. When it expires, the
framework release hook receives the actual transport and engine to
perform its normal cleanup, with a reason string; it must not attach
another engine to the released transport. Active streams and pending
H2/H3 credit-blocked work are never expired.

A Client may also receive C<schedule_timer =E<gt> sub { ... }> for
application requests specifying C<timeout> in seconds. The callback
receives the delay and an expiry callback, schedules a future framework
timer and returns a coderef that cancels the timer. No additional socket
or network buffering layer is required. The timeout covers queueing,
connection establishment and the active transaction. The connection
factory may return an optional cancellation coderef that aborts unfinished
establishment; if a request is cancelled or expires while its factory is
pending, the pool discards any later readiness callback. The framework
must clean up late, unused connections rather than feeding them to HTTP.

C<defer> is necessary because the engine may invoke on_finish before its
own response-retirement bookkeeping has unwound. Deferring new dispatch
prevents re-entering an HTTP/1 engine from that callback.

A factory failure uses C<$ready-E<gt>(error =E<gt> $reason)>. A request that
never reached an engine calls on_error/on_finish with the request operation
handle rather than pretending that an engine transaction exists. Do not
automatically retry requests when connection outcome is ambiguous.

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
