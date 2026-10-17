# Unblock::HTTP

Unblock::HTTP is the framework-neutral application layer above HTTP/1,
HTTP/2, HTTP/3, and eventually WebSocket. Protocol parsing stays in the
existing engines. This distribution adds no XS.

This feature branch is under development. The reusable Server and direct
connection attachment are implemented, along with the first shared Client
factory, request-handle, bounded queue and pooling slice. WebSocket transitions,
cross-host Alt-Svc and post-dispatch retries remain unimplemented; optional
framework-driven request deadlines are now available. The
buffered and streamed callbacks require the coordinated engine feature
branches. Read [implementation status](docs/IMPLEMENTATION.md) before using
the branch. It is not a release candidate.

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

`on_headers($tx, $request)` runs first. By default the engine buffers up to
1 MiB, then calls `on_request($tx, $request)` with the complete frozen request.
Set `max_buffered_body_bytes` in a protocol hash to change that positive limit.

For streaming, register `$tx->on_data(sub { my ($tx, $bytes) = @_; ... })`
during `on_headers`. This suppresses full-body accumulation. `on_request`
still runs after successful body completion. Failed or cancelled bodies do
not reach it. Register `$tx->on_finish(...)` before the transaction is terminal
to observe completion, error, or cancellation exactly once.

This requires `feature/unified-receive-lifecycle` in HTTP1, HTTP2 and HTTP3.
Released H1/H2 0.11 and H3 0.12 lack these primitives. Attachment checks the
required methods and gives an explicit error for an older engine.

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

## Shared Client (development)

The Client now owns reusable HTTP policy, request scheduling, and per-origin
connection pools. An application makes one Client for many destinations:

```perl
my $op = $client->request(
    method => 'GET',
    url => 'https://example.com/data',
    on_response => sub {
        my ($tx, $response) = @_;
        print $response->status, "\\n";
    },
);
```

The request returns an operation handle right away. Its `transaction()` is
undefined while waiting for a connection, then becomes the **real engine
Transaction** after dispatch. `cancel()`, `state()`, and `error()` work
without polling. A strict `http_version => '3'` requires HTTP/3, not a
fallback to HTTP/2. HTTPS cold requests use H2/H1 ALPN; later requests may use H3
through an authenticated, fresh, same-host Alt-Svc advertisement.

An integration supplies `connect_stream`, `connect_quic` and a `defer`
callback. The factory opens TCP/TLS or QUIC through its framework and calls
`$ready->(...)`. **The ready callback returns the real connected engine.**
The adapter keeps that engine on its framework-owned stream or connection and
feeds input directly to it. The `defer` callback schedules work in a later
event-loop turn. See `perldoc Unblock::HTTP::Client` and
`perldoc Unblock::HTTP::Integration` for the exact contracts.

By default the Client buffers up to 1 MiB of response data in the chosen
engine, then calls `on_response` once after body completion. Supplying
`on_data` automatically streams the response: `on_response` fires when
headers arrive, then `on_data($tx, $chunk)`, `on_end($tx)`, and terminal
`on_finish($tx)`. Client buffering does not add another body accumulator.

A request may set `timeout => $seconds` to cover queuing, establishment,
and its active HTTP transaction. The framework adapter supplies an optional
`schedule_timer($seconds, $callback)` constructor callback returning a timer
cancellation coderef. A timed-out active request cancels its real engine
transaction and reports a timeout on the operation. A factory can return
a cancellation coderef so a timed-out or manually cancelled connection
attempt releases its pool slot; late factory readiness is ignored.

When HTTP/3 QUIC bidi stream credit is exhausted, an unsubmitted
request stays in the bounded Client queue; the H3 engine notifies when
request stream availability changes, and the Client retries admission
only after framework deferral. No submitted request is replayed.

Idle connection eviction is opt-in with `idle_timeout => $seconds`.
When enabled, the framework supplies `schedule_timer` and may supply
`release_connection($host, $engine, $protocol, $reason)` to close its own
socket or QUIC resources. Timers are cancelled on reuse and never close
connections with active streams or queued requests waiting for peer credit.

The queue defaults to 128 pending requests, with at most four connections per
origin and 32 concurrent streams per H2/H3 connection. An H1 connection runs
one request at a time. The limits are adjustable. Pool idle expiry, validated
DNS HTTPS discovery, WebSocket upgrades and convenience framework connector
classes are future milestones. Authenticated same-host Alt-Svc now permits
future requests to select HTTP/3. Advertisements are only learned when
the TCP factory explicitly reports verified_origin => 1 after certificate
and origin hostname verification. When advertised HTTP/3 is selected, the
QUIC factory receives alternative_host and alternative_port and must confirm
verified_origin => 1 before the request can be sent. A failed advertised
QUIC connection may safely fall back before dispatch; a request already
submitted to an engine is never automatically replayed. This is **not** a release candidate.

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
