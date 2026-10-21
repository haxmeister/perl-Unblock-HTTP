# Real Linux::Event integration tests

These tests use the real protocol engines and local kernel sockets. They are
intentionally excluded from the CPAN tarball because Linux::Event is an
optional host framework.

Run after installing Unblock::HTTP1/2/3, Net::QUIC, and Linux::Event 0.117+:

    perl Makefile.PL
    make
    make test
    prove -v -b xt/linux-event-tcp.t xt/linux-event-websocket.t xt/linux-event-websocket-tls.t xt/linux-event-quic.t

- linux-event-tcp.t: HTTP/1.1 and HTTP/2 prior-knowledge round trips with
  Linux::Event listener/stream objects and the unified Client/Server API.
- linux-event-websocket.t: real TCP HTTP/1.1 Upgrade and HTTP/2
  prior-knowledge Extended CONNECT with the unified WebSocket
  Client/Server, ordinary HTTP reuse and socket-versus-stream pool
  ownership. Uses optional Linux::Event on both sides.
- linux-event-websocket-tls.t: real encrypted H2 WebSocket Extended
  CONNECT using Linux::Event OpenSSL TLS, generated localhost certificate,
  verified hostname/chain and negotiated h2 ALPN; ordinary H2 traffic
  shares the same authenticated connection. Requires the openssl executable.
- linux-event-quic.t: HTTP/3 client/server round trip through the QUIC
  session manager, Linux::Event UDP sockets, and independent timers. It
  generates a temporary localhost certificate using openssl.

Tests have explicit timeouts. A failure or missing module should be treated
as a failure of the integration job, not silently skipped. The isolated
distribution tests remain runnable without Linux::Event installed.
