# Unblock::HTTP 0.03 - release preparation

Status: **release-prepared source candidate, not published**. The maintainer
authorized fast-forward merging this feature into main, bumping the
version and preparing a release. Creating tags, GitHub releases and CPAN
uploads requires separate approval.

## Changes

- `Client->request(on_transaction => sub ($tx) { ... })` delivers the
  real engine Transaction once a queued operation is admitted, allowing
  a streaming producer to start without a second buffering layer.
- `on_handoff` supports HTTP/1 Upgrade/CONNECT socket-wide handoff and
  HTTP/2/HTTP/3 Extended CONNECT stream-local handoff for both Client
  and Server. Successful and rejected connections, peer SETTINGS,
  EOF, backpressure and callback lifetime are covered by tests.
- Recovered HTTP/3 request-stream credit cancels any speculative
  connecting factory that no longer has demand. Client shutdown
  closes leftover connectors, preventing orphaned UDP sockets/timers.
- HTTP2 and HTTP3 protocol packages are optional and loaded only when
  enabled. The default HTTP1 installation has no H2/H3/QUIC requirement.

## Dependencies

- Version: **0.03** across all five public modules.
- Perl >= 5.20, Uniform::HTTP >= 0.06, URI and
  **Unblock::HTTP1 >= 0.13** required.
- Optional HTTP2: **Unblock::HTTP2 >= 0.13**.
- Optional HTTP3: **Unblock::HTTP3 >= 0.14**.
- Optional WebSocket integration remains separately installed.
- No event-loop runtime dependency, Linux-specific parser path or
  included framework adapter.

## Verification and publication gate

The HTTP1-only CI installs the prepared HTTP1 0.13 main source before
running H1-only tests and disttest; it must prove HTTP2/HTTP3/QUIC and
WebSocket are not required for ordinary use. The existing
Linux::Event integration workflows exercise representative real TCP,
TLS and QUIC consumers of the generic API using the prepared engine
main revisions. They do not introduce production adapter modules.

The `release-cpan-installability.yml` workflow is reserved for a later
explicit run **after** the dependency releases have been published and
indexed on CPAN. It must use released CPAN versions, not source pins,
to establish actual public installability. No successful source-tree
CI test substitutes for that gate.

Check source MANIFEST, generated META.json provides / optional features,
PAUSE version index, distcheck, disttest, public POD, and all five
module versions before publication. No GitHub tag/release or CPAN
upload has been performed.
