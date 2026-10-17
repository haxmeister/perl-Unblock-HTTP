package Unblock::HTTP::Server;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use Unblock::HTTP::_Policy;
use Unblock::HTTP::_EngineFactory;

our $VERSION = '0.01';

sub new {
    my ($class, @args) = @_;
    croak 'new(): expected named arguments' if @args % 2;
    my %options = @args;
    my (%protocols, %callbacks);
    for my $name (qw(http1 http2 http3)) {
        $protocols{$name} = delete $options{$name} if exists $options{$name};
    }
    for my $name (qw(on_headers on_request on_error)) {
        next unless exists $options{$name};
        my $callback = delete $options{$name};
        croak "new(): $name must be a coderef" unless ref($callback) eq 'CODE';
        $callbacks{$name} = $callback;
    }
    croak 'new(): unknown option: ' . join(', ', sort keys %options) if %options;
    croak 'new(): on_request callback is required' unless $callbacks{on_request};
    return bless {
        policy => Unblock::HTTP::_Policy->new(%protocols),
        # Map once at definition time; no transaction or body wrapper.
        callbacks => {
            on_request => $callbacks{on_headers} || \&_ignore_headers,
            on_request_end => $callbacks{on_request},
            ($callbacks{on_error} ? (on_error => $callbacks{on_error}) : ()),
        },
    }, $class;
}

sub _ignore_headers { return }

sub protocols { return $_[0]{policy}->protocols }
sub alpn_protocols { return $_[0]{policy}->alpn_protocols }
sub supports { return $_[0]{policy}->enabled($_[1]) }

sub attach_stream {
    my ($self, @args) = @_;
    croak 'attach_stream(): expected named arguments' if @args % 2;
    my %options = @args;
    croak 'attach_stream(): specify either protocol or alpn, not both'
        if exists($options{protocol}) && exists($options{alpn});
    my $transport = delete $options{transport};
    my $protocol = delete $options{protocol};
    my $alpn = delete $options{alpn};
    croak 'attach_stream(): unknown option: ' . join(', ', sort keys %options) if %options;
    croak 'attach_stream(): protocol and alpn must be scalars'
        if ref($protocol) || ref($alpn);
    $protocol = defined($alpn) && length($alpn) ? $alpn : 'http/1.1'
        unless defined $protocol;
    croak "attach_stream(): unsupported byte-stream protocol '$protocol'"
        unless $protocol eq 'http/1.1' || $protocol eq 'h2';
    my $engine_options = $self->{policy}->options($protocol);
    croak 'attach_stream(): transport must be an object' unless blessed($transport);
    for my $method (qw(unblock_send unblock_finish unblock_abort)) {
        croak "attach_stream(): transport must implement $method()"
            unless $transport->can($method);
    }
    return Unblock::HTTP::_EngineFactory->create(
        'Server', $protocol, %$engine_options,
        %{ $self->{callbacks} }, transport => $transport,
    );
}

sub attach_quic {
    my ($self, @args) = @_;
    croak 'attach_quic(): expected named arguments' if @args % 2;
    my %options = @args;
    my $connection = delete $options{connection};
    croak 'attach_quic(): unknown option: ' . join(', ', sort keys %options) if %options;
    my $engine_options = $self->{policy}->options('h3');
    croak 'attach_quic(): connection must be a QUIC connection object'
        unless blessed($connection) && $connection->can('ready') && $connection->can('closed');
    croak 'attach_quic(): connection is closed' if $connection->closed;
    croak 'attach_quic(): connection is not ready' unless $connection->ready;
    my $engine = Unblock::HTTP::_EngineFactory->create(
        'Server', 'h3', %$engine_options,
        %{ $self->{callbacks} }, quic => $connection,
    );
    $engine->start;
    return $engine;
}

1;

__END__

=head1 NAME

Unblock::HTTP::Server - Shared HTTP server policy and connection attachment

=head1 SYNOPSIS

    my $server = Unblock::HTTP::Server->new(
        http1 => {},
        http2 => {},
        on_request => sub {
            my ($tx, $request) = @_;
            $tx->respond(status => 200, body => "hello\n");
        },
    );

    # For each accepted connection, in the framework adapter:
    my $engine = $server->attach_stream(
        transport => $stream,
        alpn => $negotiated_alpn,
    );
    $engine->input($bytes);

=head1 IMPLEMENTATION STATUS

This feature branch implements reusable attachment and ordinary buffered or
streamed requests. It requires the receive/lifecycle feature branches of the
three engines; released H1/H2 0.11 and H3 0.12 do not provide these methods.
WebSocket transitions remain planned. Initial Client factories and bounded
pooling are implemented separately in Unblock::HTTP::Client.
See docs/IMPLEMENTATION.md. This is not a release candidate.

=head1 CONSTRUCTOR

=head2 new

Enable each protocol with C<http1 =E<gt> {}>, C<http2 =E<gt> {}>, or
C<http3 =E<gt> {}>. An omitted protocol is disabled. At least one is required.
Each hash can contain engine tuning options. Policy copies hash and array
containers so changing a caller's settings does not change future connections.
Engine-specific object values retain their identity.

C<on_request> is required. C<on_headers> and C<on_error> are optional.
Connection and callback options may not be hidden inside a protocol's tuning hash.

Each protocol defaults to bounded buffered reception with a 1 MiB limit.
Set C<max_buffered_body_bytes> in its protocol hash to change the positive
byte limit. C<receive_body> is managed by this layer; select streaming with
C<$tx-E<gt>on_data(...)> during C<on_headers>. The engine owns the buffer.

=head2 Request callbacks

C<on_headers($tx, $request)> runs after headers, before body delivery.
The same real engine transaction and Uniform request are passed to
C<on_request($tx, $request)> once the body and trailers finish successfully.
In buffered mode, C<$request-E<gt>body> holds the complete body, including
an empty string for an empty body. The message is frozen before C<on_request>.
A failed or cancelled body does not call C<on_request>.

For streamed requests:

    on_headers => sub {
        my ($tx) = @_;
        $tx->on_data(sub {
            my ($tx, $bytes) = @_;
            consume_chunk($bytes);
        });
        $tx->on_finish(sub {
            my ($tx) = @_;
            record_outcome($tx->state);
        });
    },
    on_request => sub {
        my ($tx) = @_;
        $tx->respond(status => 204);
    },

C<on_data> selects streaming and suppresses full-body accumulation. It must
be registered before the first body byte. C<on_request> still runs after
successful streamed reception. C<on_finish> runs once after completion,
cancellation, or error; it waits for the response side too. Register it
before the transaction is terminal. Its exceptions do not undo cleanup.
C<on_error> retains the engine's arguments: transaction, error, and an
optional protocol error code. Cancellation alone is not an error.

C<websocket =E<gt> 0> is accepted in each protocol hash. Enabling WebSocket
currently fails explicitly. Extended CONNECT advertising is disabled in
H2/H3 for this stage; conflicting engine tuning is rejected.

=head1 METHODS

=head2 attach_stream

Accepts C<transport> and either C<alpn> or C<protocol>. The transport provides
C<unblock_send>, C<unblock_finish>, and C<unblock_abort>. It retains the
returned real HTTP1 or HTTP2 Server engine and feeds bytes directly to it.
There is no intermediate connection wrapper and no transaction wrapper.

Missing or empty ALPN selects HTTP/1.1 only if HTTP/1.1 is enabled. Unknown
or disabled protocols fail. Explicit C<protocol =E<gt> 'h2'> is for cleartext
prior knowledge. HTTP/3 cannot be attached to a byte stream.

=head2 attach_quic

Accepts C<connection> containing a ready, open QUIC connection negotiated
for HTTP/3. Returns a started real HTTP3 Server engine. The caller retains
it until the connection closes. UDP and timer events still go to the QUIC
Driver, never to an HTTP byte input method.

=head2 protocols

Returns enabled wire protocol names in list context: C<http/1.1>, C<h2>,
and/or C<h3>.

=head2 alpn_protocols

Returns enabled TCP/TLS ALPN choices, preferring C<h2> over C<http/1.1>.
The framework uses this list when configuring TLS. HTTP/3 uses a separate
QUIC listener and is not included in this list.

=head2 supports

C<supports($protocol)> reports whether a wire protocol name is enabled.

=head1 OWNERSHIP

One Server definition can serve many connections. It does not own listeners,
sockets, engine registries, or a network queue. The framework retains each
returned engine. Engine callbacks retain their original identity.

=head1 LICENSE

MIT License.

=cut
