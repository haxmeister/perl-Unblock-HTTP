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
- 59 isolated test assertions pass using stub engines and Driver. Real protocol integration
  has NOT been tested in this environment because the engines are not installed.

## Architecture decisions not settled

- Is one object per connection the desired top-layer API, or should Server also
  manage a listener's accepted connections?
- QUIC manager implemented; verify live driver, handshake, and memory cleanup.
- Which server-side protocol detection and negotiation features should be
  automatic (TLS ALPN, cleartext H2 prior knowledge, H2C Upgrade)?
- Should there be shared client connection selection or only existing connected
  stream/QUIC attachment? No user-agent policy or connection pools by default.

## Next steps

1. Review the public API with the maintainer before treating it as stable.
2. Exercise real HTTP1 and HTTP2 attached transports on Linux::Event.
3. Exercise HTTP3 QUIC manager against a live Net::QUIC::Driver with UDP and timers.
4. Add real integration tests and separate app usage from adapter examples.
5. Benchmark the wrapper against calling the engines directly.
6. Full release audit only after all three paths are tested.

## Design constraints

- No XS added to this distribution.
- No duplicated parser, HTTP message model, or native ABI.
- No compatibility aliases or needless method injection.
- No async/await requirement.
- Handoff stays in git and is excluded from CPAN packages.
