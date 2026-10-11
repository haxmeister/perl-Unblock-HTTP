# Unblock::HTTP handoff

Repository: haxmeister/perl-Unblock-HTTP
Project boundary: Change only this distribution unless explicitly authorized.

## Intent

Unblock::HTTP is the pure-Perl application layer above Unblock::HTTP1,
Unblock::HTTP2, and Unblock::HTTP3. It must use the modern 0.11 engines,
retain Uniform::HTTP message contracts, and remain independent of event loops.

## Working feature branch (not merged)

- Client and Server have a common constructor and protocol selector.
- Both expose the native engine through backend(), without wrapping transactions.
- HTTP/1 and HTTP/2 use an attached framework byte transport.
- HTTP/3 can use a pre-existing QUIC connection, or QUIC manager for all sessions.
- QUIC manager delegates UDP and timers to Net::QUIC::Driver and owns per-connection HTTP3 lifecycle.
- Unknown ALPN is rejected rather than guessed.
- 72 isolated regression assertions pass, including adapter callback behavior.
- Added optional Linux::Event Stream adapter with direct engine input forwarding.
- Added real socket integration tests under xt/ for HTTP/1.1, H2 prior knowledge,
  and H3 over UDP/QUIC, plus a CI workflow to install dependencies and run them.
- Real GitHub Actions integration completed successfully at:
  https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/38109612686
  It installed HTTP1/2/3 0.11 from current repository sources,
  Linux::Event 0.117, and Net::QUIC 0.04.
- The two live socket tests passed all 10 assertions:
  HTTP/1.1 over TCP, HTTP/2 prior knowledge over TCP, and HTTP/3
  over UDP/QUIC including handshake, request, and response body.
- The execution container lacks these native engine dependencies, so its
  local run covers the isolated regression suite only.
- The live socket tests did not verify TLS ALPN selection for HTTP/1/2,
  redirects, pooling, performance, or HTTP/1-to-HTTP/2 upgrade.

## Architecture decisions not settled

- Is one object per connection the desired top-layer API, or should Server also
  manage a listener's accepted connections?
- QUIC manager live UDP handshake and request verified; additional
  lifecycle, concurrency and memory retention audits remain.
- Which server-side protocol detection and negotiation features should be
  automatic (TLS ALPN, cleartext H2 prior knowledge, H2C Upgrade)?
- Should there be shared client connection selection or only existing connected
  stream/QUIC attachment? No user-agent policy or connection pools by default.

## Next steps

1. Review the public API with the maintainer before declaring it stable.
2. Add a real TLS ALPN negotiation test covering H1 and H2.
3. Benchmark the wrapper and Linux::Event adapter against direct engines.
4. Investigate optional reusable Linux::Event client adapter ergonomics.
5. Add stream backpressure, delayed responses, cancellation and lifecycle
   stress tests for the QUIC manager.
6. Conduct a full POD, packaging, smoke and release audit before release.

## Design constraints

- No XS added to this distribution.
- No duplicated parser, HTTP message model, or native ABI.
- No compatibility aliases or needless method injection.
- No async/await requirement.
- Handoff stays in git and is excluded from CPAN packages.
