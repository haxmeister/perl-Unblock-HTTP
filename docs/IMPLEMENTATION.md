# Implementation status and continuation plan

Updated: 2026-10-17
Branch: feature/high-level-client-server
Status: development checkpoint, not a release candidate.

## Implemented

Server is a reusable definition with shared protocol policy. attach_stream
returns the actual H1/H2 Server engine; attach_quic returns the actual started
H3 Server engine. Frameworks retain those engines and own sockets and timers.
The optional LinuxEvent adapter feeds the selected engine directly. QUIC
server managers attach each ready connection through the shared definition.

Only explicitly enabled protocols can attach. Settings containers are copied.
No transaction wrapper, subclass, reblessing, or method injection is used.
The whole-buffer output contract is unchanged.

Ordinary Server callbacks now have the intended application timing:

- on_headers($tx, $request): incoming headers, before body delivery.
- on_request($tx, $request): successful complete body and trailers.
- on_error($tx, $error, optional code): underlying engine failure.

Each protocol defaults to buffered reception capped at 1 MiB. Change the
positive max_buffered_body_bytes option in that protocol's tuning hash.
Register tx->on_data during on_headers to select streaming without a full
body accumulator. on_request still runs once on successful streamed reception.
Register tx->on_finish before terminal state to observe complete/error/cancelled.
A completed request can still have an unfinished response.

The engine owns reception and installs the body before freezing the same
Uniform message. The upper layer stores no body chunks and maps callbacks
once when constructing the shared definition. There is no per-chunk forwarding
closure in the unified layer.

Old upper-layer on_body and on_request_end constructor options are removed,
without aliases. They remain low-level interfaces in the individual engines.

## Coordinated dependency branches

The user explicitly authorized changes to HTTP1, HTTP2, HTTP3 and this repo.
All dependency work is on feature/unified-receive-lifecycle. Main branches
remain untouched. See ENGINE-CONTRACTS.md and each engine's Handoff.md.

H1/H2 add bounded buffering while retaining their default stream mode. H3
retains its buffered default and reuses its existing accumulator/Reader.
All add on_data and on_finish. H3 body-limit failure now resets its stream
instead of failing the connection. Native ABI layouts remain unchanged.

Released H1/H2 0.11 and H3 0.12 lack these methods. Attachment rejects old
engines explicitly. Feature versions have not been bumped for release.
Do not install this upper branch with released engines and expect it to work.

## Validation

Local Perl 5.38.2, 2026-10-17:

- HTTP1: 36 files, 320 top-level tests/subtests pass.
- HTTP2: 30 files, 525 top-level tests/subtests pass.
- Upper layer: 6 files, 182 top-level tests/subtests pass. Five files use engine
  doubles; t/14-server-receive.t runs real H1/H2 attached engines.

The new engine tests cover buffered/streamed bodies, limits, empty bodies,
cancellation, object identity, callback ordering and native/portable parity.
H1 also covers chunked trailers, truncation, and throwing completion/error
callbacks. H2 covers simultaneous streams and overflow isolation.

H1 uses Uniform::HTTP 0.06 from the read-only dependency checkout. H2 was built
against the actual system nghttp2 1.59.0 shared library and matching upstream
headers, using a scratch build configuration because Alien::nghttp2 is absent.
The repository Makefile.PL is unchanged.

H3 native/ownership/terminal tests pass locally: 3 files, 92 top-level checks.
The local native build uses upstream nghttp3 1.18.90 development and cannot
run live QUIC because Net::QUIC is not installed locally.

Full GitHub CI now passes for all three engines, including live H3 tests:

- HTTP1 test 39058702399 and framework examples 39058702329.
- HTTP2 test 39058704851 and interoperability 39058704842.
- HTTP3 test 39059118633 (26 files / 942 top-level tests/subtests) on
  Perl 5.20, 5.28, 5.36, 5.44, with distribution/POD/installed ABI checks.
  Interoperability 39059118732 also passed.

CI uses the released dependency configuration. The upper workflow pins the
published engine source revisions listed in Handoff.md. Initial integration
39058779436 passed; strengthened final integration 39059172525 also passed
(182 distribution checks and 15 live TCP/QUIC checks).
It checks H1/H2 TCP and an H3 POST over QUIC/TLS, including complete body,
transaction/message identity, frozen message and lifecycle order.

## Next steps

1. Ordinary Server receive/lifecycle milestone is complete and CI verified.
2. Keep all four feature branches; no merge, release or version bump is authorized.
3. Publication and CI fixes are already authorized. Do not ask for the same
   confirmation again. Main branches and read-only dependencies stay unchanged.
4. Continue the original design after verifying this ordinary Server milestone.
   No benchmark improvement is claimed.

## Later design milestones

Client remains the old single-connection interface. The shared Client, transport
factories, request-operation handle, bounded scheduling, connection pooling,
validated Alt-Svc cache and retry policy are pending.

WebSocket enablement is rejected. H2/H3 Extended CONNECT advertising is disabled.
The raw H1 engine can still issue 101; a complete WebSocket permission gate and
protocol handoff are pending. Needed engine work includes supported transaction
construction extensions, H1 successor-consumer routing, H2/H3 safe stream
composition, and bounded pause/resume. These are not part of this first receive
milestone. No Net::QUIC modifications are authorized.

Complete live stress tests, direct-engine benchmarks, and final application
versus adapter documentation before considering a release. The original
approved design remains in design-handoff.txt.
