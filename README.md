# Unblock::HTTP

Unblock::HTTP is the framework-neutral application layer above HTTP/1,
HTTP/2, HTTP/3, and eventually WebSocket. Protocol parsing stays in the
existing engines. This distribution adds no XS.

This feature branch is under development. The reusable Server and direct
connection attachment are implemented. Client pooling, automatic connection
creation, buffered application callbacks, and WebSocket transitions are not
implemented yet. Read [implementation status](docs/IMPLEMENTATION.md) before
using the branch. It is not a release candidate.

## One Server, many connections

Application code creates one definition:

```perl
use Unblock::HTTP::Server;

my $server = Unblock::HTTP::Server->new(
    http1 => {},
    http2 => {},
    http3 => {},
    on_request => sub {
        my ($tx, $request) = @_;
        $tx->respond(status => 200, body => "hello\n");
    },
);
```

An omitted protocol is disabled. Each protocol hash can carry engine tuning
options. `websocket => 0` is accepted; enabling it currently fails explicitly.

At this checkpoint, `on_request` still runs when headers arrive, using the
existing engine contract. `on_body` receives body chunks and `on_request_end`
runs after the body and trailers. The planned default buffering and later
application `on_request` timing need additional engine support.

## Framework attachment

For each incoming TCP/TLS connection, the adapter attaches its stream:

```perl
my $engine = $server->attach_stream(
    transport => $stream,
    alpn => $negotiated_alpn,
);

$engine->input($bytes);
```

The returned object is the actual HTTP1 or HTTP2 Server engine. Transactions
also come directly from that engine. There is no forwarding connection object.
The framework retains the engine and continues to own its socket and buffers.

The stream supplies `unblock_send`, `unblock_finish`, and `unblock_abort`.
`unblock_send` accepts the entire buffer or throws. A defined false result
means the bytes were accepted but the host is congested. The framework calls
`resume_output()` when it has capacity again.

Configure TLS using `$server->alpn_protocols`. This returns enabled TCP choices,
with H2 preferred. Empty ALPN selects H1 only when H1 is enabled. Unknown or
disabled protocols fail. For cleartext H2 prior knowledge, pass
`protocol => 'h2'` instead of `alpn`.

A ready HTTP/3 QUIC connection uses:

```perl
my $engine = $server->attach_quic(connection => $ready_h3_connection);
```

It returns a started HTTP3 Server engine. UDP and timer events continue to go
to `Net::QUIC::Driver`. The framework is responsible for supplying a connection
negotiated for H3. A QUIC manager can attach all ready connections to the same
definition:

```perl
my $endpoint = Unblock::HTTP::QUIC->server(
    server => $server,
    certificate_file => $cert,
    private_key_file => $key,
    send => $send_datagram,
    set_timeout => $replace_timer,
);
$endpoint->start;
```

Read `perldoc Unblock::HTTP::Integration` for the adapter contract.

## Client status

Client still represents one existing connection at this checkpoint:

```perl
my $client = Unblock::HTTP::Client->new(
    transport => $stream,
    alpn => $negotiated_alpn,
);
$client->request(
    method => 'GET', target => '/', authority => 'example.test',
    on_response => sub { my ($tx, $response) = @_; },
);
```

Its existing callbacks follow the engine contract. The approved next stages
replace this with one Client managing destinations, bounded request scheduling,
connection reuse, protocol selection, and discovery. Redirects, cookies,
routing and middleware remain outside this distribution.

## Examples and tests

The optional Linux::Event examples are:

- `examples/linux-event-server.pl`: a shared Server with H1/H2 attachment.
- `examples/linux-event-quic-server.pl`: a shared Server with a QUIC manager.

Each separates application behavior from framework plumbing. The core does
not require Linux::Event. Core requires Perl 5.20; this optional adapter uses
Perl 5.36 syntax.

Run isolated contract tests:

    prove -lr t

Run the live tests after installing the real engines, Linux::Event and Net::QUIC:

    prove -l xt/linux-event-tcp.t xt/linux-event-quic.t

The isolated suite uses test doubles. Its success does not establish wire-level
correctness or native ABI compatibility. The live suite currently covers basic
cleartext H1/H2 and QUIC H3 exchanges; broader coverage is still planned.

## License

MIT License.
