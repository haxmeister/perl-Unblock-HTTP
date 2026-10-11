# Unblock::HTTP

Unblock::HTTP provides one application interface for HTTP/1, HTTP/2, and
HTTP/3. It builds on Unblock::HTTP1, Unblock::HTTP2, Unblock::HTTP3, and
Uniform::HTTP.

The implementation is pure Perl. It selects an existing protocol engine;
it does not parse HTTP frames itself or wrap every Transaction.

## Server

```perl
use Unblock::HTTP::Server;

my $http = Unblock::HTTP::Server->new(
    transport  => $stream,
    alpn       => $negotiated_alpn,
    on_request => sub {
        my ($tx, $request) = @_;
        $tx->respond(status => 200, body => "hello\n");
    },
);
```

The event-framework stream feeds incoming decrypted bytes to
`$http->input($bytes)`. It implements `unblock_send`, `unblock_finish`,
and `unblock_abort` to accept outgoing bytes. This is the same attached
transport contract for HTTP/1 and HTTP/2.

## Client

```perl
use Unblock::HTTP::Client;

my $http = Unblock::HTTP::Client->new(
    transport => $stream,
    alpn      => $negotiated_alpn,
);

$http->request(
    method    => 'GET',
    target    => '/',
    authority => 'example.test',
    on_response => sub {
        my ($tx, $response) = @_;
        print $response->status, "\n";
    },
);
```

Application callbacks receive the underlying Transaction, with common
`respond`, `write`, `end`, and lifecycle methods. Advanced protocol-specific
features remain available through `$http->backend`.

## Selecting the protocol

- Empty or absent ALPN on a byte stream uses HTTP/1.1.
- `h2` selects HTTP/2.
- `h3` uses an existing Net::QUIC connection instead of a byte stream.

A cleartext HTTP/2 prior-knowledge connection can pass `protocol => 'h2'`.
Only the negotiated TLS ALPN result should be passed as `alpn`.

For HTTP/3:

```perl
my $http = Unblock::HTTP::Server->new(
    quic       => $ready_quic_connection,
    on_request => $on_request,
);
$http->start;
```

The host integrates UDP and the timer through Net::QUIC::Driver, as before.
A convenience manager can now create and activate all HTTP/3 sessions:

```perl
use Unblock::HTTP::QUIC;

my $endpoint = Unblock::HTTP::QUIC->server(
    certificate_file => $cert,
    private_key_file => $key,
    send        => $send_datagram,
    set_timeout => $replace_timer,
    on_request  => $on_request,
);
$endpoint->start;
# Forward UDP events with $endpoint->receive, timeout, and writable.
```

This avoids writing the connection-discovery and handshake-readiness loop.
The host still manages its own UDP socket and timer.

## Scope

The top layer is event-loop neutral and creates no sockets or TLS contexts.
It does not implement an HTTP user agent, connection pool, redirects,
cookies, or framework-specific adapter. It selects and delegates to the
existing protocol engines. Protocol detection and richer QUIC integration
will be built as separate, tested features.

Requires Perl 5.20 or newer because the included HTTP/3 engine requires it.

The Linux::Event examples are `examples/linux-event-server.pl` for H1/H2 and
`examples/linux-event-quic-server.pl` for H3.

Read `perldoc Unblock::HTTP::Integration` for the precise transport contract.

## License

MIT License.