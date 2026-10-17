# Implementation status and continuation plan

Updated: 2026-10-17
Branch: feature/high-level-client-server
Status: Server, Client pool, Alt-Svc and optional deadlines CI verified. Not a release candidate.

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

## Shared Client implementation slice (2026-10-17)

The first Client slice has been committed to the upper feature branch.
Client is now a reusable policy and per-origin connection pool, not the
older one-connection forwarding wrapper. Factories are callback-based and
framework-neutral: connect_stream(origin, alpn_choices, ready),
connect_quic(origin, ready), and defer(callback). The ready callback returns
the real HTTP1/2/3 engine. Frameworks retain the engine and socket; the pool
does not forward input bytes.

request(method => ..., url => ...) returns _ClientOperation immediately,
including while connecting. operation->transaction is the real engine
Transaction once dispatched. A strict http_version (1.1/2/3) must match.
Cold requests prefer existing H2/H1 negotiations, not unvalidated H3
discovery. HTTP3-only and explicit HTTP3 requests use connect_quic. The
pool enforces positive limits: pending queue 128, connections/origin 4,
multiplexed requests/connection 32 by default. Idle H1 is reusable,
H2/H3 capacity is shared, and incompatible idle engines can be evicted.
The defer factory prevents reentering H1 from its finish callback.

The engine performs the only buffered reception (default 1 MiB).
Without on_data, on_response runs after successful completed response;
with on_data, on_response runs at headers and on_end at body completion.
on_finish runs after transaction terminal state. A pre-dispatch failure or
cancellation has no engine tx, so callbacks receive the request operation.
No automatic retries are attempted. HTTP 404/500 are responses, not errors.

New isolated contract file t/15-client-pool.t covers factories, streaming,
terminal callbacks, queue cap, multiplexing, H1 deferred reuse, strict
protocols, and error/cancellation. The previous t/10 selector test now
tests _Session as a low-level helper. The old QUIC client manager now
returns the actual HTTP3 Client engine rather than constructing the
obsolete one-connection unified Client. The live TCP test is converted
to the new Client factory API.

Validation checkpoint: CI run 39061708958 passed the distribution suite
(7 files / 245 checks); its live TCP test still used the old Client API.
The replacement live TCP test exposed an H2 Client constructor rejection of
the Server-only enable_connect_protocol option, also applicable to the H3
enable_extended_connect option. Client now removes these before constructing
H2/H3 engines. Verified Client pool CI: run 39062331531 passed all 256 distribution
checks and 15 live TCP/QUIC checks at commit df6fa8ea. No local shell git checkout is possible in this session because
github.com DNS resolution fails; edits/publication used the GitHub connector.

## Alt-Svc discovery and safe connection fallback (2026-10-17)

Implemented on the upper feature branch in this follow-up:

- A bounded in-memory Alt-Svc cache. Accepts the same-host h3=":PORT"
  syntax on authenticated HTTPS responses only, with one origin-scoped
  entry, a maximum lifetime of 24 hours, Age adjustment, clear handling,
  stale entry removal and bounded cache size (256 origins).
- Framework connect_stream must return verified_origin => 1 after TLS
  certificate/hostname validation against the request origin before
  Alt-Svc headers are trusted. Merely setting a URL scheme to https
  does not establish TLS authentication.
- Subsequent requests with no strict http_version may choose H3. The
  connect_quic factory gets the original origin plus alternative_host
  and alternative_port, then must return verified_origin => 1 to confirm
  the alternative is authoritative for the ORIGINAL origin. The request's
  scheme, authority and target are unchanged.
- Cross-host alternative services are deliberately unsupported for now.
  No silent TLS verification bypass, DNS discovery, 0-RTT or connection race.
- A failed advertised QUIC connection may fall back to existing TCP
  BEFORE dispatch, because no HTTP request has been transmitted. This
  does not invoke application on_error, does not retry a strict version
  and invalidates the failed advertisement. After engine request()
  dispatch, there is never an automatic replay, even for GET; the
  application sees the original error.
- Unit tests in t/16-alt-svc.t and integration tests in
  t/17-alt-svc-client.t cover parser/expiry/authentication, strict
  selection, factory failure and prevention of unsafe request replay.

Alt-Svc source/test commit 557cb101e5cd2342368d43f18afc400e69546634
passed integration CI run 39062960467: 9 distribution test files, 316 checks,
and 2 live H1/H2/H3 tests, 15 checks. Source and POD were reviewed again
after that run. Server and all three engine branch sources remain unchanged.

## Optional request deadlines and factory cancellation (2026-10-17)

A Client now accepts optional schedule_timer(seconds, callback) returning a
timer cancellation coderef. Requests may specify timeout as a positive number
of seconds covering time spent queued, connecting and active. No native timer
or event-loop dependency is introduced. The timer is cancelled when the
operation reaches a terminal state.

A connecting operation can abandon its in-flight factory without keeping
the per-origin connection slot occupied. If the factory returned a cancellation
coderef it is called; any late ready() is ignored. The framework must dispose
of a transport it created after cancellation. The operation retains native
engine identity and no unprocessed request is automatically replayed.

Pre-dispatch expiry emits on_error(operation, reason) before
on_finish(operation). After dispatch the real engine Transaction is cancelled
and the Client emits on_error(tx, timeout reason) before on_finish(tx). The
operation records an error, while the underlying transaction reflects the
actual cancellation, not a fabricated protocol failure. Explicit user
cancellation remains separate and does not invoke on_error.

t/18-client-timeouts.t supplies deterministic framework-timer and fake
transport tests, including late factory readiness, queue release and
callback ordering. The live HTTP1/H2 tests also use actual framework timers,
confirming successful operation cleanup.

Run 39064100968 passed at commit f8be6219a7db440b8fe38acbcf5741066f7c488d:
10 distribution test files / 371 checks and two live TCP/QUIC test files /
17 checks. After this run, the upper Client and t/15 gained an additional
terminal callback dispatch guard and regression: a request enqueued inside
H1 on_finish must wait for the next framework deferred turn instead of
reentering the engine. Final CI for this guard is pending.

## Later design milestones

Cross-host Alt-Svc, DNS HTTPS discovery, retries after engine dispatch,
request timeout policy, peer-aware multiplexed capacity and pool idle
cleanup are pending. These will need real multi-request socket tests.

WebSocket enablement is rejected. H2/H3 Extended CONNECT advertising is disabled.
The raw H1 engine can still issue 101; a complete WebSocket permission gate and
protocol handoff are pending. Needed engine work includes supported transaction
construction extensions, H1 successor-consumer routing, H2/H3 safe stream
composition, and bounded pause/resume. These are not part of this first receive
milestone. No Net::QUIC modifications are authorized.

Complete live stress tests, direct-engine benchmarks, and final application
versus adapter documentation before considering a release. The original
approved design remains in design-handoff.txt.
