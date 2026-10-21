# Integration readiness review - October 20, 2026

Scope: haxmeister/perl-Unblock-HTTP on feature/high-level-client-server
and the existing read-only engine feature branches. This is a correctness
and developer-experience review, NOT a release audit or release plan.
Do not modify main, merge, tag, or bump versions as part of this review.

## Confirmed implementation coverage

| Application operation | HTTP/1.1 | HTTP/2 | HTTP/3 |
| --- | --- | --- | --- |
| Ordinary buffered/streamed Client and Server | Implemented | Implemented | Implemented |
| Server WebSocket | 101 Upgrade | 200 Extended CONNECT | 200 Extended CONNECT |
| Client connect_websocket | 101 Upgrade | 200 Extended CONNECT | 200 Extended CONNECT |
| Socket/stream ownership | Whole socket switches consumer | One H2 request stream | One QUIC H3 request stream |
| WebSocket output | Existing ordered socket queue | Per-stream deferred writer | Per-stream deferred writer |
| Peer Extended CONNECT setting | Not needed | Required before CONNECT | Current peer SETTINGS required |
| Peer stream-credit gate | One H1 operation per socket | H2 transaction credit | H3 QUIC bidi-stream credit |
| Request cancellation | H1 transaction / WebSocket | Stream-local cancellation | Stream-local cancellation |

Successful in-memory H1/H2 and real localhost QUIC/TLS H3 Client+Server
tests are in the distribution suite. The H3 Client milestone passed
both full integration workflows at source
a3f429edf66562a55ab23e0d5b55a8e3eb989b7c:
published Net::QUIC run 39516674510 and optional MAX_DATA
run 39516674529, 29 test files / 1,170 checks. No throughput
improvement is inferred from the diagnostic smokes.

The existing Linux::Event integration suite exercises live TCP and QUIC
sockets and output/backpressure semantics, but is not proof of
interoperability with external browsers or frameworks. An additional
live H1 Upgrade/H2 prior-knowledge WebSocket regression
(xt/linux-event-websocket.t) has been added. Its new CI outcome must
be checked separately before calling that coverage verified.

## Application and adapter examples

- examples/linux-event-websocket-server.pl: one app definition, real
  Linux::Event adapter, H1 default or H2 prior knowledge by environment.
- examples/linux-event-quic-websocket-server.pl: one H3 app definition,
  QUIC/TLS server manager, one Linux::Event UDP socket and timer.
- examples/linux-event-websocket-client.pl: shared H1/H2 Client,
  event-loop TCP connection factory, socket-consumer handoff and
  application-only WebSocket callbacks; cleartext local demo.
- docs/WEBSOCKET-COOKBOOK.md: commands, app-versus-adapter separation,
  TLS caveats, Client invocation, ownership checklist.
- lib/Unblock/HTTP/Integration.pm: the event-loop-neutral contract.
- Both full CI workflows now compile-check all shipped example programs.
  This only verifies that imports and syntax work, not runtime behavior.

The application handlers see the original HTTP Transaction and the
actual WebSocket session. The adapter does not parse HTTP or WebSocket.
H2/H3 defer callbacks MUST schedule a later event-loop turn.

## Remaining integration/readiness gaps

1. **Coordinated branches are not a release set.** The upper module's
   Makefile.PL declares minimum released engine versions, but its
   receive/lifecycle and WebSocket integration use coordinated engine
   feature-branch APIs. Simply installing the minimum published versions
   does not establish the required feature contract. Current CI
   explicitly pins those branches. Do not present this feature branch
   as ready to install independently from CPAN.
2. **Native H1 input ownership remains framework-specific.** A
   borrowed-input provider that receives INPUT_SWITCH must feed the
   unconsumed suffix into the successor WebSocket consumer exactly once.
   The ordinary Perl input path and a native transition test exist,
   but the upper layer cannot access an external native provider's
   borrowed window without its cooperation.
3. **TLS/ALPN and independent peer interoperability.** H2 is covered by
   real engines and now has a Linux::Event cleartext prior-knowledge
   regression pending CI. That is not a full TLS ALPN WebSocket
   interoperability test. H3 is covered by real QUIC/TLS loopback using
   the project's engines; third-party RFC 8441/9220 peers have not been
   established by these tests.
4. **Connection factories remain framework callbacks.** A runnable
   Linux::Event shared Client example now covers local H1/H2 TCP
   sockets. A generic framework-independent TCP/TLS connector and a
   standalone application H3 Client QUIC/TLS factory are still not
   shipped. Do not imply that `connect_websocket` creates sockets
   without adapter code.
5. **Deliberately absent features.** Cross-host Alt-Svc routing, DNS
   HTTPS record discovery, post-dispatch replay and automatic protocol
   downgrade for explicit WebSocket version selection are not supplied.
   They are not required for the currently approved callback-first API.

## Next small, useful steps

First verify the example compilation and new live H1/H2 WebSocket
regression in both CI tracks, fixing only evidence-based failures.
The shared-Client TCP transport example has now been added. Next,
test a real TLS ALPN H2 WebSocket exchange and, if test tools are
available, at least one external Extended CONNECT peer. A separate
H3 QUIC/TLS shared Client factory example can follow the proven t/36
harness. Do not start a broad profiling or release campaign.

Dependencies explicitly remain read-only: Unblock::HTTP1/2/3,
Unblock::WebSocket, Uniform::HTTP and Net::QUIC. All implementation
writes stay on the upper feature branch. Recheck Handoff.md and
CI results before further changes.
