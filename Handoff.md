# Unblock::HTTP implementation handoff

Updated: 2026-10-17
Repository: haxmeister/perl-Unblock-HTTP
Branch: feature/high-level-client-server
Status: Server, Client, Alt-Svc, deadlines, H3 credit wakeup and idle pooling CI verified.

## Resume here

Read this file, docs/design-handoff.txt, docs/IMPLEMENTATION.md and
docs/ENGINE-CONTRACTS.md. Inspect git status and branch before editing.
The user requested frequent handoff updates for continuation in another chat.

The user authorized changes to this repo and HTTP1/HTTP2/HTTP3, then explicitly
confirmed feature publication and coordinated CI. Do not ask again for those
pushes or branch fixes. ALL main branches must remain untouched. Do not merge,
release or bump versions. Net::QUIC and Uniform::HTTP are read-only dependencies.

Upper branch: feature/high-level-client-server.
All engine branches: feature/unified-receive-lifecycle.

## Client milestone continuation (2026-10-17)

Branch/ref verification: all four published heads matched the supplied handoff at
start of this session; shell clone/fetch is unavailable in this workspace (DNS).
GitHub connector is the only publication path. No repository files in a local
git working tree were available at session start. Use connector refs with
explicit branch selection; do not modify main.

Concrete implementation order:

1. Replace the old one-connection Client with a reusable definition accepting
   http1/http2/http3 policy, asynchronous connect_stream/connect_quic framework
   factories, and a framework defer callback. No socket/TLS/timer management in
   the core. Explicit selection honors strict per-request http_version.
2. Return a request-operation handle immediately (including before a connect
   completes); keep the actual engine Transaction in operation->transaction
   once issued. The operation is not a transaction wrapper.
3. Enforce a finite request queue and finite per-origin connection/stream
   capacities; reuse idle H1 connections and H2/H3 multiplexed capacity.
   Schedule next requests via framework defer after transaction completion to
   avoid invoking H1 again inside its on_finish stack.
4. Map early streaming on_response/on_data/on_end and late buffered on_response
   onto native callbacks. Use the engine's one receive buffer and native tx.
5. Add isolated factory/queue/cancellation/pooling tests, then live engine tests.
   Next milestone after this slice: validated Alt-Svc cache/discovery, safe
   method/transport-aware retries, and WebSocket upgrades later.

Implementation now committed on the upper feature branch: reusable Client,
_ClientOperation, framework factories, strict version selection, bounded
per-origin H1/H2/H3 pool, deferred H1 reuse, Client callback sequencing,
low-level QUIC helper direct H3 engine, docs, and t/15-client-pool.t.
No dependency source changes were needed. CI source 700dbd20 passed all
245 distribution checks; the live test still used the former Client and
failed. The converted live test then exposed H2 Server-only CONNECT option
leaking into Client constructors; that and the H3 equivalent are corrected.
Added regression checks and strict idle-connection eviction. Upper integration
run 39062105591 PASSED on feature commit
5d956aa1e0f83ebe83a03b447d2f4377fab27e01: 7 distribution files /
256 top-level checks plus 2 live TCP/QUIC files / 15 checks. H1 and H2
live requests use new shared Client factories; H3 low-level manager returns
the real engine. Later docs/handoff commits do not change that tested source.
No performance benchmark has run.

Do not infer Alt-Svc, retries, WebSocket, DNS HTTPS discovery, timed factory
cancellation or final pool capacity policy from this first slice.

## Alt-Svc and retry continuation (2026-10-17)

Before edits: verified current upper feature head df6fa8ea4987d2d6702aeb387f0e219eacbe39e2;
last CI 39062331531 SUCCESS (256 distribution and 15 live checks). Engine feature
refs unchanged. Main is off limits. No local checkout available in this turn;
connector writes specify only the upper feature branch.

Coherent next slice:

1. Small bounded in-memory Alt-Svc cache, isolated parser, explicit freshness
   (ma / Age / clear / expiry). Start with same-host h3 alternatives only;
   discard cross-host and malformed alternatives rather than advertise
   authentication that has not been established. Cache only headers from
   framework-confirmed TLS-authenticated HTTPS responses. Do not infer
   authentication solely from a URL scheme.
2. On subsequent non-strict requests select a fresh h3 alternative. Pass
   original origin authority and alternative UDP port separately to QUIC
   connection factory, while preserving request origin semantics. Require
   that the returned QUIC connection is verified authoritative for the
   original origin before dispatch. Strict http_version continues to win.
3. Failed alternative connection before request dispatch may safely fall
   back once to TCP for the same pending operation (no request transmitted).
   Invalidate stale discovery. No replay once an engine request() has been
   called, regardless of HTTP method; do not infer unprocessed requests from
   transport or stream errors.
4. Add unit cases for parsing, authentication, explicit version precedence,
   expiry, clear, failure fallback, unsafe replay guards; run distribution
   and live integration CI. Update docs and this handoff as tested.

Implemented in _AltSvc.pm and Client.pm on this upper feature branch.
Same-host h3=":port" advertisements are accepted from authenticated HTTPS
responses only, and the QUIC factory must attest TLS authentication for
the original origin before dispatch. Expiry, Age, ma, clear and bounded
in-memory entries are covered. Cross-host Alt-Svc is not implemented.
Unsent advertised QUIC requests (including POST) may fall back once to TCP;
already dispatched requests are never replayed, even GET.

Verification: CI run 39062960467 passed at source commit
557cb101e5cd2342368d43f18afc400e69546634 with 9 distribution files /
316 top-level checks and 2 live TCP/QUIC tests / 15 checks.
Additional API documentation and verified_origin normalization commits were
also CI-green (39063045212, 39063081185, 39063084160). The latter are
source/documentation corrections, not new engine dependency changes.
No speedup or zero-copy claim has been made.

## Request deadline and stale factory slice (2026-10-17)

Resume checkpoint: upper feature head 6be05992db9e7d8d7d0076dd2c4d563f932faa9a
passed CI run 39063244495. All engine branches and all main refs match the
previous handoff; no engine or read-only dependency source changes planned.

Implementation sequence:

1. Introduce optional framework schedule_timer(seconds, callback) => cancel
   callback. Require it only for requests using a positive timeout in seconds.
   The timeout covers queue, connect and active response lifetime, not a
   separate network-only phase. Do not use internal blocking timers or poll.
2. Terminal pre-dispatch timeout calls on_error(operation, error) and then
   on_finish(operation), with no engine transaction or automatic replay.
   Active timeout cancels the real engine tx; the operation records timeout
   as failure, delivers on_error(tx, error) before on_finish(tx), and retains
   engine cancellation semantics instead of fabricating a parser error.
3. Track a specific in-flight connection attempt; cancellation/timeout of its
   initiating request releases the pool connection slot. Optional factory
   cancellation callback aborts pending establishment. Late ready() calls
   are ignored, never attached or dispatched. Request callback queue remains
   bounded and avoids synchronous engine reentrancy.
4. Cover synchronous/late factory callbacks, expired queued/active requests,
   double cancel, exactly-once error/finish and timer cleanup with deterministic
   fake framework timers; verify live unchanged H1/H2/H3 CI. Keep this slice
   isolated from peer-stream capacity and post-dispatch automatic retries.

Implementation now published on the upper feature branch:
- Client accepts optional schedule_timer(seconds, callback), returning a
  timer-cancellation coderef; request(timeout => seconds) covers queue,
  establishment and active transaction lifetime.
- _ClientOperation stores/cancels its timer on terminal notification.
- Client tracks one concrete factory attempt per origin. When a pending
  initiating operation times out or cancels, the attempt slot is freed and
  an optional factory cancellation hook is invoked. Stale ready() calls do
  not create engines or dispatch requests.
- An active timeout invokes actual engine Transaction->cancel, while the
  operation reports timeout as an error. on_error(tx, reason) precedes
  on_finish(tx); intentional cancellation has no manufactured error.
- t/18-client-timeouts.t covers deterministic timer, cancellation, callback
  ordering and late factory edge cases. The live LinuxEvent TCP test uses
  a real framework timer and verifies cleanup on both H1 and H2.
- Verified CI run 39063973271 at source commit
  388dde830590dde6792e8e2c91945a4d3ee264e0: 10 distribution test
  files / 362 checks and 2 live TCP/QUIC tests / 17 checks, PASS.
  Subsequent t/18 cases for queued H1 expiry and factories without optional
  cancellation passed CI 39064100968, increasing distribution checks to
  371; the live suite still passed 17 checks. Afterward a regression was
  added for on_finish creating another H1 request: _pump now defers this
  dispatch until after the current engine terminal callback unwinds. The
  terminal reentrancy commit passed CI run 39064232198, tested source
  69c79094e742b07bbba5ee01ad4cd09ccfa2a03a:
  10 distribution test files / 375 checks, plus 2 live TCP/QUIC tests /
  17 checks, all PASS. Latest documentation-only commits follow this
  source checkpoint. The feature branch is not release-ready.
- No engine, Net::QUIC or Uniform::HTTP source was modified. No performance
  claim has been measured. Broad live concurrency and peer-aware capacity
  coordination remain later work.

## Client pool admission and retirement (2026-10-17)

Starting refs verified: upper 21d6899d234dc157715ac4385d02b3733a65ef05,
HTTP1 99edf2fa99816a383915cd1a0989dda93036a495,
HTTP2 51fb1ad9ef97ff7a4451b10d14a505df4d55fae4,
HTTP3 e35bd69874cb45ea37094cf58e9ed807b46ad6d9.
All upper CI through run 39064361372 PASS; main refs unchanged.
There is no network-capable shell checkout in this session, so edits are
published directly through the GitHub connector to the feature ref.

Admission review: H2 Client->can_open_transaction respects peer
SETTINGS_MAX_CONCURRENT_STREAMS, local active cap and draining.
H3 Connection->_submit_request returns undef if QUIC open_bidi_stream
has no credit. The H3 Client has no public can_open_transaction or
availability event for the pool. Do not pretend configured upper limits
are peer credit; do not re-submit or auto-replay a dispatched request.

Planned slice:
1. Prevent synchronous factory completion loops when a connected H2
   peer advertises zero concurrent streams or a connection immediately
   becomes non-admitting. Bound new connection attempts per pump, and
   do not spin/allocate unbounded connections during reentrant callbacks.
2. Respect H2 admission/draining while distinguishing busy (temporarily
   full) connections from idle retired connections. Reap unusable idle
   engines; never abort active transactions for capacity reclamation.
   Enforce the per-origin connection limit and bounded queue.
3. Detect an H3 request() result of undef. A request has not been
   admitted; do not mark it active forever, do not call on_finish on a
   made-up transaction, and do not blindly replay. Surface a terminal
   admission error unless a real engine notification API is added later.
4. Add adversarial pool tests for zero-capacity peer, reentrant factory
   completion, draining H2, strictly-versioned queue behavior, and
   simultaneous origins. Extend the live TCP integration with concurrent
   client traffic. Verify new source CI before marking complete.

Implemented and published on the upper feature branch:
- H2 admission respects the real engine can_open_transaction, including peer
  SETTINGS_MAX_CONCURRENT_STREAMS and draining/GOAWAY. Zero temporary peer
  credit does not close a healthy connection. on_settings schedules a pump
  so queued requests resume when peer credit increases.
- Draining H2 and GOAWAY H3 engines are retired when idle, never while active.
  Connection caps remain enforced while outstanding streams complete.
- Synchronous factories are limited to the per-origin connection budget per
  pump, preventing endless creation on a non-admitting peer.
- A request returning undef from H3 engine->request (no QUIC bidi stream
  credit) now reports one explicit pre-dispatch non-admission error and
  releases its active slot; it cannot fabricate a Transaction or replay.
  A ready connection without request capacity is recorded as queued, not
  connecting.
- New t/19-client-admission.t exercises zero/increased SETTINGS, draining H2,
  synchronous factories, H3 no-credit/GOAWAY, and six independent origins.
- The live TCP test now submits 12 H1 and 12 H2 requests with framework
  owned timers. Initial run exposed a TEST-ONLY adapter bug: its old factory
  attached several engine instances to one TCP stream. Corrected factory
  creates a distinct LinuxEvent stream per connection. All 24 requests
  completed with the corrected adapter.
- Verified integration source CI: run 39065677169 on
  e13e5004e60e3df28875d5164b61e3e74459bb9c passed 11 distribution
  files / 419 checks plus 2 live TCP/QUIC files / 19 checks.
- Later documentation-only commits clarify one-engine-per-socket and API
  capacity limits; no engine repository source was changed.

Remaining: H3 engine/QUIC stream availability notification is not exposed
to the shared Client; current no-credit admission fails explicitly rather
than queuing indefinitely. Peer-credit callback contract, automated
network-change invalidation, idle cleanup, further fairness and load
benchmarks remain subsequent milestones. No performance gains claimed.

Unchanged: original-engine and Uniform identities, callback-first
application API, transport-owned buffers, no required XS, strict HTTP
version, timeout semantics, and no replay after dispatch.

## H3 request stream credit continuation (2026-10-17)

Starting feature refs: upper e540559ca43bce8b15fc8c71d148f82e863ca858;
HTTP3 e35bd69874cb45ea37094cf58e9ed807b46ad6d9.
Upper CI 39065824604 is green. All main refs unchanged.
GitHub connector is the branch-specific publication path.

Design: Net::QUIC::Connection already emits an on_stream_available
callback with 'bidi' and 'uni' event types. HTTP3 must keep its existing
ownership of that callback and forward a narrowly scoped
on_request_available($h3_client) notification only after request()
previously returned undef because open_bidi_stream yielded no stream.
Events for uni streams or unrelated activity do not notify. The HTTP3
callback is advisory, not a persistent stream-credit counter. HTTP3
retains transport/flow-control ownership and no Net::QUIC modifications.

Unblock::HTTP Client must preserve a failed-to-admit (unsent) request
in its finite queue, not report an error or construct a fake tx.
Mark that H3 engine credit-blocked until it notifies; then defer the
scheduler through the framework and reattempt only the still-unissued
request. The real transaction remains the engine's returned object
once admitted. Strict version and timeout/cancel rules remain intact.
No automatic retry for any dispatched request.

Tests: H3 engine fake QUIC bidi exhaustion and bidi/uni notifications;
upper deterministic blocked queue, callback wakeup, cancellation and
per-origin caps; CI for the H3 feature and upper pinned integration.
Update the upper CI pin only to a verified H3 feature source SHA.
No release, version bump, merge, or changes to main.

Implemented and published on upper feature branch:
- HTTP3 source 9bfd9314fb66f19860a96a20ec6eb082e86e3ce5 is
  pinned in .github/workflows/linux-event-integration.yml.
- The shared Client passes H3 on_request_available at engine creation,
  preserving its existing QUIC ownership. The callback weakly references
  the pooled connection and schedules (not inlines) a scheduler pump.
- If H3 request() returns undef before any QUIC stream was opened,
  the Client restores that exact operation to the head of the bounded
  queue and flags the connection credit-blocked. It cannot resend a
  transmitted request or create a synthetic Transaction.
- Bidi availability clears credit-blocked and schedules a deferred
  admission attempt. Cancellation or timeout removes the queued
  operation, and late credit notifications cannot resurrect it.
- t/19-client-admission.t now covers blocked -> notified -> dispatched,
  another blocked request behind it, callback deferral, cancellation,
  deadline while blocked, queue bounds, and exactly-once callbacks.
- Verified source/test CI run 39069827594 PASS at source checkpoint
  5887d192c82110bd991e65a7dda5234bdd357fe8:
  11 distribution files / 444 checks and 2 live files / 19 checks.
  That run includes the pinned new H3 dependency.
- The live QUIC test was then upgraded to use a framework-owned
  Net::QUIC::Driver and shared multi-origin Client connection factory;
  unlike the previous test's low-level QUIC manager, this verifies
  the application Client path over authenticated real sockets. Await
  its separate final CI run before marking live adaptation verified.
  Verified shared-Client real QUIC/TLS integration: run 39069934513
  PASS on commit 944d3841eedf3adda088e9f7dd05c8c44ad3be87:
  11 distribution test files / 444 checks and two live TCP/QUIC files /
  19 checks. The live HTTP3 POST was sent by the upper multi-origin
  Client, through Net::QUIC::Driver and the real H3 feature engine.
  A subsequent trivial ready-attachment guard and this handoff edit
  change no HTTP request/transport semantics.
No main/ref changes, releases, version bumps, merges or changes to
Net::QUIC / Uniform::HTTP. H3 engine unit/matrix CI and interop are
recorded in its own Handoff.md.

## Client idle connection lifecycle continuation (2026-10-17)

Read/verified the four upper design handoffs and the existing Client.
Current upper feature ref 51570c966a2a523427d67a7f2ecbd47ef6769aa1
passes CI run 39070083547. Engine refs and all main refs are unchanged.
This is a coordinated feature-only continuation, not release preparation.

Design chosen for this slice:
- Optional idle_timeout in seconds (no default idle timeout; preserve
  existing integrations). Requires schedule_timer only when requested.
- Optional release_connection($host, $engine, $protocol, $reason) callback
  for frameworks to dispose of transports/QUIC resources. The core can
  close an engine/QUIC connection if no hook is supplied; engine close is
  not a substitute for a framework-owned stream when the hook is used.
- One timer for each actually idle pooled connection; cancel on reuse.
  Re-arm at latest completion, never while active requests are present
  or while queued demand is blocked on peer SETTINGS/QUIC credit.
- When the timer fires, retire only if still idle/current in its pool.
  Do not close active streams or make a queued operation terminal.
  Clean empty origin pools and stale closed/retired engines. Release
  callbacks are at most once for each transport/engine pair, including
  explicit capacity eviction.
- Deterministic timer/connection tests, protocol-specific retirement,
  real TCP/QUIC smoke, and wider H3 multiplexing test. Record verified CI.
- No event-loop integration in the production Client, native callback
  wrappers, unbounded timers, or automatic post-dispatch retry.
No source edits to H1/H2/H3/QUIC/Uniform are expected.

Implemented on the upper feature branch:
- idle_timeout is opt-in, in seconds, requiring framework schedule_timer.
  Idle timers are per idle connection, cancelled on reuse; zero active
  transactions is insufficient when queued work is blocked on H2 SETTINGS
  or H3 QUIC credit. Stale timers cannot close reused connections.
- Optional release_connection(host, engine, protocol, reason) allows
  adapter-owned resource cleanup. Defaults to engine->close if supported,
  otherwise QUIC connection->close. Releases are guarded to run once.
- Pool pruning and strict-protocol idle eviction now release resources.
  Empty origin pools are removed when idle connections expire.
- t/20-client-idle.t covers H1 idle reuse, timer cancellation, H2
  multiplex last-stream cleanup, zero-peer-credit protection, H3
  cleanup and strict cap evictions.
- The real QUIC/TLS integration test now runs eight concurrent HTTP3
  POST requests over a single shared Client connection and checks
  distinct Uniform messages, real engine transaction identity,
  complete request/response bodies and exact callback order without
  assuming which stream completes first.
- Verified code and tests: CI run 39073163329 PASS on
  a0b8a0164e741e55010c954b1f35f0e7ee350e98.
  12 distribution files / 487 checks plus 2 live TCP/QUIC
  files / 78 checks. Subsequent commits only expand Client/Integration
  POD, README and docs/IMPLEMENTATION.md.
- No engine source change, release, version bump, merge, tag or main edit.
  Net::QUIC and Uniform::HTTP remain read-only.

Outstanding: network-change invalidation and pool status API, broader
stream/backpressure stress and direct-engine performance comparisons,
WebSocket integration and final application/framework adapter examples.

## Explicit network-change invalidation and Client pool snapshot (2026-10-17)

Starting verified upper feature head 7151b6cabc921d77fb0c443042123af024ad3fa2;
CI 39073350222 passed. H1/H2/H3 feature refs and all main refs were
checked and remain unchanged. No engine, QUIC or Uniform source edits planned.

Implementation contract for this slice:
- Client->network_changed() is an explicit framework call, not polling or
  implicit OS network detection. Clear the entire cached Alt-Svc set,
  invalidate pending Alt-Svc preference before dispatch, cancel in-flight
  factories through the existing optional cancellation hook, and ignore
  their late readiness. Pending operations keep their identity, timeout
  and position in the finite queue, and are re-scheduled after deferral.
- Mark established connections stale for future requests. Retire their
  idle engines immediately through the existing one-shot release hook;
  active transactions are not cancelled or replayed. Stale connections
  consume their existing origin capacity until active streams finish.
  On completion, retire them and admit queued operations on fresh sockets.
- In-flight responses from old network transports cannot repopulate
  Alt-Svc after invalidation. An additional explicit invalidation is safe.
- Client->pool_stats() returns a read-only copied snapshot with totals and
  per-origin counts for pending, connecting, active, idle, credit-blocked
  and stale connections. It must not return engine, QUIC or socket objects,
  and must not mutate scheduling state or create timers.
- Deterministic tests for pending Alt-Svc, old active H1/H2 streams,
  connection factory cancellation/late callback, H3 credit-block,
  repeated invalidation, idle timer cleanup and snapshot stability.
  Verify CI and refresh this handoff after source/test commits.

No fabricated post-dispatch retry, no network sniffing in Client, no
unbounded buffers or per-body event wrappers.

Implemented and published to the upper feature branch:
- Client->network_changed explicitly clears every Alt-Svc entry, abandons
  connecting factories and ignores their late ready callbacks. Pending
  operations retain the same identity, queue positions and deadlines.
  Advertised h3 preference in unsent work returns to ordinary TCP policy.
- Idle old-network connections and timers are released immediately through
  the one-time framework hook. Active engines remain alive but are marked
  stale and released only after terminal callbacks; queue resumes on fresh
  sockets without replaying already-issued requests.
- Old-network connections are prohibited from populating new Alt-Svc hints
  after invalidation. Repeated network_changed calls are harmless.
- Client->pool_stats returns a detached numeric aggregate and per-origin
  snapshot of pending, connecting, connection, active, idle, retiring and
  stream-credit-blocked counts, without retaining socket/engine references.
- New t/21-client-network.t (53 checks) exercises factory cancellation,
  late readiness, active H2 survival, stale cache, idle-timer cleanup,
  repeated changes, H3 credit-blocked migration and snapshot immutability.
- Source/test and MANIFEST CI 39073823298 PASS at
  9727113f5f85382f69026af74b67e7b5ac643aaf:
  13 distribution test files / 540 checks and 2 live TCP/QUIC files /
  78 checks. Subsequent changes update POD, README and docs only.
- No H1/H2/H3/Net::QUIC/Uniform modifications; no main edits, merges,
  tags, version bumps or releases.

Next: backpressure and large-body live stress, pooled-vs-direct-engine
performance measurements, framework/application examples and WebSocket
integration. Explicit network detection remains the adapter's job.

## Real streaming and backpressure continuation (2026-10-17)

Starting upper feature ref 699b695d673e97a6a2ba153bcea3d07e83b163b7
and CI run 39073970857 PASS. All H1/H2/H3 feature refs and all four
main baselines were verified unchanged. Required approved design and
engine contract documents reviewed before editing.

Implement narrow, measurable validation before optimizing:
1. Add LinuxEvent real TCP integration exercising both H1 and H2 with
   concurrent POST bodies larger than default 1 MiB receive buffering,
   registering server transaction on_data at headers. Client response
   registers on_data automatically (no stream_response flag) and receives
   large responses through its real engine transaction. Record bytes,
   checksums, callback sequencing, exact finish and no response buffering.
2. Exercise network backpressure via framework-owned socket output and
   writable events, preserving native engine on_drain behavior; no
   per-chunk helper added to the upper Server.
3. Keep resource/test limits modest and deterministic (bounded payloads,
   watchdog, no network external dependencies). Ensure normal buffered
   workflows remain green. Verify via coordinated Github Actions CI.
4. Build or document a direct-versus-upper protocol-engine comparison
   harness only after a reliable same-workload fixture is available.
   No throughput/latency gains or copies avoided will be asserted without
   measured before/after results.

Completed and verified on the upper feature branch:
- xt/linux-event-streaming.t exercises three concurrent POST requests
  under both H1 and H2 with 1,179,648-byte uploads and responses.
  Incoming server and client on_data callbacks process data incrementally
  across multiple chunks, with SHA-256 integrity, exact byte counts,
  native transaction identity and header/end/finish callback ordering.
  Both receive sides use the existing engine-owned stream/buffer path;
  no extra per-chunk forwarding layer was added to Unblock::HTTP.
- The live QUIC/TLS test additionally mixes a 1,179,648-byte streamed
  upload/response with seven ordinary buffered HTTP3 POSTs on one QUIC
  connection. It checks per-stream identity, body digests, final callbacks
  and isolation despite out-of-order completion.
- Controlled backpressure in the test TCP framework returns defined false
  after it has ACCEPTED bytes, and then invokes the real engine
  resume_output method on a framework timer. Both H1 and H2 survive
  this test and deliver every byte once. This is a protocol-contract
  stress test, NOT a claim of testing an actual slow peer or bounded
  socket memory under sustained congestion.
- Integration workflow now executes xt/linux-event-streaming.t alongside
  H1/H2 and QUIC live tests. Verified source CI run 39075534537 PASS:
  13 distribution files / 540 checks and 3 live files / 145 checks.
  Additional H3-streamed run 39075394995 passed 540/141 before
  synthetic transport-pressure checks were added.
- bench/client-vs-direct.pl compares real H1/H2 client engines against
  the upper Client using the SAME upper Server and LinuxEvent sockets,
  warmed single-request-at-a-time loopback traffic, and alternating
  direct-first/unified-first rounds. docs/BENCHMARKING.md documents
  its limits and how to reproduce it. The CI workflow smoke-runs
  1000 timed requests / 100 warmup per mode in 3 rounds and has no
  rate threshold.
- First repeated baseline, CI 39076051442 (pre-optimization):
  median H1 direct 0.28021 s, unified 0.37543 s per 1000 requests
  (ratio 1.340); H2 direct 0.26195, unified 0.35947 (1.372).
- Removed a redundant scheduled pool-maintenance pass after a healthy
  completion with no queued demand, idle timer, or connection retirement.
  Preserved deferred reentrancy, idle timers and stale-connection cleanup.
  Added three deterministic tests in t/15-client-pool.t.
  CI 39076255077 PASS at source/test commit
  55b8b85636a7d886a314080c9db1450e67ec15c3:
  13 distribution files / 543 checks and 3 live files / 145 checks.
  Repeated benchmark medians (1000 requests): H1 direct 0.27318 s,
  unified 0.35407 s (1.296); H2 direct 0.25810, unified 0.34514
  (1.337). Direction is encouraging but runner-to-runner differences
  mean this is NOT proof of a stable percent speedup.
- No source edits to H1/H2/H3, Net::QUIC or Uniform::HTTP. All changes
  are on the upper feature branch; main remains unchanged. No merge,
  release, tag or version bump.

Remaining work: controlled profiling to separate URI/request creation,
pool dispatch, framework scheduling and engine work; realistic sustained
slow-consumer/backpressure with memory queue limits; H2/H3 concurrent
fairness and direct H3 baseline; high-load latency percentiles, copies
and allocation measurements. The observed unified Client overhead
in this constrained workload is still material and must not be hidden.
No unmeasured "zero-copy" or broad performance claims should be made.

## Client request-path profiling continuation (2026-10-17)

Starting feature refs verified: upper e755e2405b954ccbcf7cc7c390caaff91cf6c911;
H1 99edf2fa99816a383915cd1a0989dda93036a495;
H2 51fb1ad9ef97ff7a4451b10d14a505df4d55fae4;
H3 b093bcf8c05bacaa8e674896cb342c797d7ef138.
All four main refs unchanged. Latest upper CI 39076525306 PASS
(543 distribution / 145 live checks). The previous handoff's measured
three-round benchmark ratio remained ~1.30 H1 and ~1.34 H2.

Next validated profiling slice:
- Extend the identical direct vs unified live TCP benchmark to report
  time spent synchronously in each mode's request() call versus elapsed
  round-trip wall time, without adding a runtime dependency or changing
  native engine hooks. Instrument both sides identically and report
  warmup-free per-request mean; keep this benchmark out of CI pass/fail
  thresholds.
- Add an isolated URI/Uniform construction microbenchmark as supporting
  evidence only, not a substitute for profiling actual sockets.
- Use measurements to select a narrow optimization; never remove URI
  validation, request identity, callback sequencing or backpressure.
- Verify with CI, leave all engine and read-only dependency sources alone,
  update this handoff with results, and preserve main/release restrictions.

Measured setup profiling CI 39079013272 PASS: 13 distribution files
/ 543 checks, 3 live files / 145 checks. 1000 measured requests with
100 warmup, 3 rounds: H1 direct median synchronous request() 45.61 us,
unified 93.18 us; H2 direct 45.22 us, unified 99.82 us. URI-only
validation microbench median 9.871 us, Uniform object-only median
10.425 us, combined 20.872 us on the same CI runner. Bench
instrumentation adds a clock call to both modes, so raw values are
not directly comparable to earlier uninstrumented runs. No production
hot-path code changed for that measurement.

Next narrow candidate: direct-dispatch a request on an already
available healthy pooled engine when the origin has no queued
operations, no in-flight factory, no callback reentrancy or deferred
maintenance, and idle expiration is disabled. The engine transaction
remains native. All other requests follow the existing bounded pump.
Add regressions to prove the shortcut is not used for queued H1 work,
active on_finish reentrancy, or idle timer lifecycle. Compare three
alternate-order CI rounds again before declaring benefit.

The candidate is now implemented and verified on the upper feature branch.
Client->request has a narrow same-origin direct-dispatch path for exactly one
ready reusable connection with native admission capacity, no pending work,
connecting factory, scheduled maintenance, callback reentrancy or configured
idle_timeout. It calls the original _dispatch against the actual engine
Transaction; nothing is reblessed or buffered. Every other case retains
the fully validated bounded _pump.

t/15-client-pool.t gained a tracked-Client regression proving that ready H2
multiplex requests bypass _pump, saturated connections continue through the
bounded pending queue, deferred completion wakes correctly, and configured
idle expiration always uses _pump. Existing tests cover H1 on_finish
reentrancy, cancellation, timeout and H3 credit. No new engine source edit.

Verification: source CI 39079217496 PASS at commit
7acf49adf21851280e1aefc851d59a9fc9a224f8 (543 distribution and 145 live).
Regression CI 39079251789 PASS at commit
4413707b34fb17745a901e5488b8b6a25f66dac5:
13 distribution files / 552 top-level checks and 3 live H1/H2/H3 files /
145 checks. The direct and unified benchmark, URI/Uniform setup microbenchmark,
and large-body/backpressure fixtures all run in that CI job.

Instrumented benchmark medians (1000 measured requests, 100 warmup, 3
alternating-order rounds; microseconds request() inclusive):
- Before direct-dispatch, CI 39079013272: H1 direct 45.61, unified 93.18;
  H2 direct 45.22, unified 99.82.
- After code-only change, CI 39079217496: H1 direct 45.10, unified 87.77;
  H2 direct 45.42, unified 95.26.
- Later regression run 39079251789 on a slower runner: H1 direct 73.67,
  unified 131.22; H2 direct 80.54, unified 148.14. Runner variability
  prevents treating the observed gap change as a precise speedup.

URI-only and Uniform-only median operations were about 9.9 and 10.4 us
in the first isolated microbench, combined ~20.9 us, so the remaining
request()-inclusive overhead also includes policy, operation allocation,
pool admission and callbacks. These components have not been individually
profiled yet. No zero-copy or production throughput claim is justified.

No main/release or engine changes. Next: profile subcomponents of Client
request construction and queue admission, plus true sustained slow-receiver
backpressure/high-water behavior. Preserve correctness, error/cancel order
and event-loop neutrality before any deeper fast-path optimization.

## Genuine slow-reader socket validation (2026-10-17)

Current verified head 68113bd06372e0376ee0d92c4d2eaa8613f0bce5,
CI 39079482114 PASS. New work stays on feature/high-level-client-server;
all engine and main refs unchanged. Read the four approved upper design
documents and Linux::Event 0.117 stream contracts first.

A previous live test injected a false return from unblock_send AFTER
acceptance. It proved that accepted-but-blocked output resumes without
duplicating data, but did NOT prove real socket send queue pressure.
This slice adds a separate bounded live integration fixture:
- Use the actual Linux::Event socket pause_read/resume_read control on
  the HTTP Client transport, with a timer and modest receive buffer.
  Server transport uses small high/low write watermarks and a multi-MiB
  streamed response with a reproducible integrity digest.
- Inspect real unblock_send=false and on_drain outcomes if the kernel
  backpressures. Validate integrity, callback order, completion, no
  early receiver-side delivery while paused, and timeout safety.
- Do not conflate a low watermark with a hard queue cap. Keep the test's
  body size bounded and do not assert peak pending bytes unless the
  framework exposes an authoritative measurement.
- Keep genuine socket pressure test separate from bench timing, and
  leave protocol engine and core API untouched unless failures expose a
  demonstrated defect. Verify via coordinated live GitHub CI.

Implemented and verified on the upper feature branch:
- New xt/linux-event-slow-reader.t uses Linux::Event's actual socket
  pause_read/resume_read controls and a constructor receive_buffer of 16 KiB
  on the client. A framework timer suspends reads for 0.12 seconds while
  a Server engine emits a bounded six-MiB response. Server output uses
  a 16 KiB high/4 KiB low watermark. No core HTTP or engine source edit.
- The test checks that no client application reads occur during the
  pause; after resume, streamed H1/H2 response byte counts, SHA-256,
  callback sequence and one-time transaction completion all succeed.
  This is an actual socket pause, unlike the earlier fixture's synthetic
  false-return acceptance/drain injection.
- CI run 39083903027 PASS at source/test commit
  5eaca204f773331eec98870bdfc5e64e948365e1:
  13 distribution files / 552 checks and 4 live TCP/QUIC files /
  168 checks, plus the existing direct/unified benchmark smoke.
  On the CI Linux runner H1 observed one actual transport
  unblock_send=false and one on_drain; H2 recorded zero of both
  while the pause/resume and full body checks still passed.
  H2 protocol flow control may throttle before transport watermarks;
  do not infer otherwise from zero transport-drain notifications.
- Two superseded CI runs initially failed because test-only code
  passed unsupported socket_options => {...} instead of the actual
  receive_buffer constructor keyword. The callback diagnostic was
  hardened to accept pre-dispatch operation handles; corrected run green.
- This does NOT measure peak queued output bytes, actual byte-copy
  counts, or worst-case sustained slow peer memory. A soft output
  high watermark is not a hard limit. LinuxEvent's max_pending_bytes
  must be handled with its documented hard-limit behavior before
  promising general bounded producer buffering.
- No H1/H2/H3, Net::QUIC, Uniform::HTTP or main edits; no merge,
  release, tag or version bump.

Remaining: actual sustained producer on_drain flow control, a hard
pending-output cap and measured queue high water, more concurrent
slow readers including HTTP/3, and per-component Client profiling.

## Sustained bounded streaming producer continuation (2026-10-17)

Starting checked upper ref 67e830016d857e2f5d2314599750b60e4ab1968a;
CI 39084123595 PASS. Engine branches and all four main refs unchanged.
Read the four upper design documents, H1/H2 engine handoffs,
Transaction streaming contracts, and LinuxEvent 0.117 ByteStream
pending_bytes/high-/low-watermark/max_pending_bytes implementations.

Next test: a genuinely paused real LinuxEvent TCP client, streaming
producer using the native server Transaction respond(stream_body=>1,
on_drain=>...) + write/end in bounded chunks. Stop immediately when
write() returns false and resume only on on_drain, without duplicating
already accepted chunks. Test H1 and H2, exact body SHA-256 and lifecycle,
producer pause and restart, fairness via bounded per-defer burst, and
measure transport->pending_bytes peak directly with a configured
max_pending_bytes hard cap. Keep test bounded and deterministic with
real LinuxEvent 0.117; do not assert engine-internal queue limits based
on transport pending bytes. No stream implementation/API changes
unless new failures expose a verified defect.

Implemented on upper feature branch:
- New xt/linux-event-producer-backpressure.t: live H1 and H2 TCP socket
  with 0.4 seconds of paused receiver reads, 8 MiB streamed response,
  8 KiB producer writes and a maximum 8-chunk burst per event-loop turn.
  Producer stops immediately when native tx->write() returns false
  (bytes accepted), and resumes only from on_drain; no replay of written
  bytes. After final blocked chunk, end() waits for the next drain.
- Server LinuxEvent stream sets high_watermark 32768,
  low_watermark 8192, max_pending_bytes 524288 and SO_SNDBUF 32768.
  pending_bytes is sampled from the framework after send and drain,
  recording the maximum sampled TCP queue. This does NOT include
  HTTP2 internal provider/flow-control bytes or kernel socket buffers,
  and the test does not attempt to force the hard cap to reject output.
- CI 39085138364 PASS on production-unchanged source/test commit
  a0fd7adb52d6126d44e73800dde7de4f4ca268e2:
  13 distribution files / 552 checks and five live files / 203 checks.
  The full direct-vs-unified and setup benchmark smoke also passed.
  Measured on that CI host: H1 51 blocked writes, 51 producer resumes,
  51 transport drains, peak sampled pending 32856 bytes; H2 95 blocked
  writes, 95 producer resumes, 64 transport drains, peak sampled pending
  32821 bytes. Both preserve full SHA256, once-only transaction finish,
  exactly one end, callback order, fairness burst and no reads
  during pause. The difference between H2 producer and socket drain
  counts is expected: engine stream flow control can block independently.
- Follow-up test-only commit 42b1f302c2fababfe9b5b2c431329ea8abf45943
  adds a guard against calling end() immediately after a final
  accepted write that returned false. Verified CI 39085334724 PASS:
  13 distribution files / 552 checks and five live files / 203 checks;
  producer block/resume and measured queue counts unchanged. This adds
  no API or engine source change.

Still unproven: worst-case memory usage across engine provider queues,
enforcement when the hard pending-output cap is actually exceeded,
partial/oversized transport write handling, sustained multi-client
slow-consumer fairness and H3 producer backpressure. Do not claim the
socket high watermark itself is a hard upper bound.

No H1/H2/H3, Net::QUIC, Uniform::HTTP or main source changes; no
merges, tags, releases or version bumps.

## Transport hard-cap failure contract (2026-10-17)

Starting ref 9e71ba158896e5be6b4cbd4b1580c458ffca0b32,
upper CI 39085500207 PASS; all 4 main refs and all 3 engine
feature heads unchanged. Reviewed original approved handoff, current
implementation/engine contracts and LinuxEvent main _ByteStream.pm
write(), _xs_output_limit and Linux::Event::Error.

Discovery: LinuxEvent max_pending_bytes is a fatal hard output limit,
not advisory producer backpressure. When a new write would exceed the
limit, LinuxEvent emits an Error(type => 'output_limit', operation
=> 'write', limit, pending_bytes) and fails the stream. The returned
false is NOT a promise that the oversized bytes were accepted. The
upper optional LinuxEvent adapter's unblock_send() checks is_closed,
dies after a synchronous fatal write and the native engine must
abort rather than invoke on_drain or replay rejected bytes.

Completed hard-limit and cross-engine correction:
- New xt/linux-event-hard-output-limit.t uses a 2 MiB buffered server
  response, a paused client read side, and LinuxEvent max_pending_bytes
  4096 to deterministically force fatal output_limit in both H1 and H2.
  Both close host, report structured type/limit/pending and never
  deliver a completed response or invoke on_drain for rejected bytes.
- Initial upper CI 39086673892 exposed a real H1 defect: H1 Server
  marked on_finish(complete) before any pipelined buffered response
  bytes were accepted by the attached host. H2 correctly marked error.
- H1 feature Server now retains complete HTTP/1 pipeline coalescing
  while deferring terminal callbacks for attached Transactions until
  the entire buffered batch is accepted by unblock_send(). A fatal
  thrown rejection marks pending transactions error, exactly once.
  False returned by a still-alive host remains complete-byte acceptance.
  Manual mode, graceful host close, native borrowed input, pipeline
  serialization and switch semantics retain their prior behavior.
- Initial H1 naive gate broke t/50 pipelined output coalescing and
  graceful close. Replaced it; did not weaken existing tests.
  New H1 t/53-attached-output-completion.t covers rejection, accepted
  congestion, pipelining and unchanged manual output. H1 source at
  783e2a951dafac2756ba2c3cf34ea35fc043de6f;
  CI matrix 39087355734 PASS on Linux 5.16/latest, macOS/latest and
  Windows 5.40: 37 files / 324 tests on Linux latest.
  H1 framework examples CI 39087355806 PASS.
- Upper workflow pin updated to verified H1 feature source SHA above.
  Unified CI 39087487036 PASS at upper commit
  b9a5a2d2a36aee14bde75be439ee3097d1bf6786:
  13 distribution files / 552 checks and six live TCP/QUIC files /
  226 checks, including H1/H2 actual fatal output_limit regressions.
  Existing direct-vs-unified and setup benchmark smoke passed.
- No source edits to HTTP2/HTTP3/Net::QUIC/Uniform; no main edits,
  merges, tags, releases or version bumps.

Next concurrent fairness checkpoint:
- New xt/linux-event-pool-fairness.t streams 2 MiB on each of three
  distinct pooled H1 or H2 connections. Two LinuxEvent clients pause
  socket reads for 0.8s while one fast client continues. Each native
  server Transaction writes no more than four 4KiB chunks per deferred
  event-loop turn and obeys on_drain. It checks that fast completion
  precedes slow receiver releases, all response digests/lengths and
  callback orders match, and every sampled socket queue stays below
  the configured 512KiB limit.
- CI 39087771958 PASS on upper source 99d19a5cd77b37ab57768af61955ddd4807cab5e:
  13 distribution files / 552 checks; seven live H1/H2/H3 files /
  289 checks. This includes normal stream tests, H3 multiplexed
  responses, H1/H2 accepted backpressure, fatal output limit, and
  three-client fairness. H1 and H2 each had three separate pooled
  sockets, both slow readers eventually resumed, and the fast
  transaction completed first.
  Observed max socket pending: H1 32832 bytes, H2 32821 bytes.
  Two native producer on_drain callbacks and two socket on_drain
  callbacks occurred per protocol. Benchmark smoke passed but its
  timing is not used as a performance claim.
- All fairness edits are upper feature tests and workflow only, no
  production Client/Server changes. Later documentation-only commits
  do not require a dependency source pin update.
- Still outstanding: forcing LinuxEvent hard cap with oversized
  writes inside a streamed response producer rather than buffered
  response; measuring engine-internal provider queues and total
  allocations; H3 response producer backpressure and fair multiplexing.


No changes to any main branch, no engine or QUIC/Uniform sources by
default, no release, tags, merge, or version bumps.

## H3 streamed response producer and QUIC flow-control continuation (2026-10-17)

Starting ref a5c5dd1b7caffe8f08e4c992167151623eb73c8a.
Upper latest CI 39087979104 PASS with 552 distribution / 289
live checks. All four main branches are unchanged. H1/H2/H3 engine
feature heads checked; Net::QUIC and Uniform::HTTP remain read-only.
Read the approved four upper docs and H3 feature Handoff.md,
Transaction.pm, Body::Stream.pm, Connection.pm before editing.

Implemented and first CI verification:
- New xt/linux-event-quic-producer.t reuses proven real UDP/QUIC/TLS
  connection, native H3 Transaction and driver callbacks. Concurrent
  work is one 2 MiB streamed response plus seven ordinary buffered
  request/response exchanges on the same authenticated QUIC socket.
  Producer writes 4096-byte chunks with a maximum four per deferred
  event-loop turn and stops on write(false). It resumes only from
  the native HTTP3 on_drain callback and defers end() if the last
  complete write reported backpressure.
- H3 server send_buffer_limit is set to 8192 bytes to expose
  protocol-level retained-body pressure. The test validates byte
  counts, streamed SHA-256, exactly one end, callback order, native
  object identity, concurrent stream isolation and bounded
  producer bursts; it does not add body forwarding in the upper API.
- CI 39088458914 PASS on upper production-unchanged source/test
  c47bd77b574f97218984c3a7c0bb96c53741aa62:
  13 distribution files / 552 checks; eight real TCP/QUIC files /
  368 checks. Native H3 producer blocks=256, resumptions=256,
  on_drain=256, event turns=257, max two chunks per turn.
  The repeat direct-vs-unified benchmark smoke also ran; those noisy
  timing samples are not a throughput performance claim.
- Follow-up strengthens mixed QUIC multiplex fairness by asserting
  at least one small H3 response completes before the large streamed
  response. CI 39088663590 PASS on source commit
  687e0a2126737b6ae940529b0921cb6998c7f011:
  13 distribution files / 552 checks and eight live files /
  369 checks, including this new assertion. The subsequent wording
  correction 3494d47227100c741d68a3a2e57b8f5c87df4e0f
  merely describes the verified assertion more precisely.
  Documentation-only commits follow it.
- H3 send_buffer_limit is a native HTTP3 retained-body threshold,
  NOT a UDP socket hard cap, aggregate QUIC buffering bound or
  memory measurement. H3 callback receipt currently consumes QUIC
  receive credit automatically, so no receiver pause is being
  simulated or inferred. Remaining: actual H3 slow reader with
  explicit receive-credit control, aggregate buffering observability,
  concurrent stress beyond eight streams, and a direct H3 baseline.

No H3/H1/H2 engine sources or Net::QUIC/Uniform changed in this H3
slice. Main, tags, releases and version numbers remain untouched.

No main/merge/release/tag/version changes. Record exact source
commits, tests, and limits here after CI.

## H3 receive-credit and Reader observation continuation (2026-10-17)

Verified starting refs: upper d3436fec36e279e8533f305235f68091df413c03;
H1 bb8349efdc5cf55d7730b40d55eff665cc3a245c;
H2 51fb1ad9ef97ff7a4451b10d14a505df4d55fae4;
H3 b093bcf8c05bacaa8e674896cb342c797d7ef138.
All main baselines still untouched. Latest upper CI 39088852131 PASS
(552 distribution tests / 369 live tests). Approved four upper docs and
H3 Handoff.md, Body::Reader, Transaction and Connection inspected.

We must distinguish *read-side* credit from the earlier native H3
send_buffer_limit. The advanced H3 pull Reader does not credit
outstanding body bytes until next_chunk() is called; callback on_data
automatically credits after return. Net::QUIC client transport accepts
small stream_window and connection_window settings without modifying
the library. Upper Client deliberately owns receive_body and defaults
buffered/no on_data, so an advanced pull-mode stress fixture should
use the existing low-level H3 Client over the upper QUIC helper,
paired with a reusable upper Server. No production API change needed.

Implemented and verified:
- New xt/linux-event-quic-reader-credit.t uses the proven upper
  QUIC manager/server and direct lower HTTP3 Client in receive_body
  => 'stream' pull mode. Net::QUIC client advertises
  stream_window => 32768 and connection_window => 131072.
- Hold Body::Reader->next_chunk() consumption for 0.5s while a
  native 4KiB/chunk H3 server Transaction streams 2 MiB. Observe
  Reader->pending_bytes, retain the queued chunks without credit
  return, and ensure a concurrent small response finishes before
  releasing credit. The slow Transaction remains nonterminal; the
  producer cannot submit the entire body until credit is returned.
- After the hold, a timer-driven pull consumer uses at most eight
  queued chunks per turn. Each next_chunk() returns the associated
  QUIC receive credit. Full body SHA-256, byte length, once-only
  completion, producer write(false)/on_drain pairs and stream
  isolation all pass. No upper Client API changes were necessary.
- Initial CI 39092684191 failed in test setup due the optional
  QUIC helper calling on_ready($h3,$manager) while test declared
  only one argument. It was corrected in the test; no production
  changes were required.
- Corrected CI 39092855745 PASS at upper test-only source
  f185fbce8a40bb1326ea65e70a0d906a1c906993:
  13 distribution files / 552 checks, 9 live TCP/QUIC files /
  387 checks, plus benchmark smoke. Observed H3 Reader
  pending_at_release=32739 bytes, maximum sampled pending=32739,
  producer blocks=257, native resumptions=257, pull polling
  turns=667. The fast request completed before the hold ended.
- Strengthened xt checks explicitly assert that the producer
  is still stalled at release and that the maximum sampled
  Reader pending stays <= the advertised 32KiB receive window.
  Source commit b352f51bed7f4b9a9b8179aaa0df28a41fc93926;
  coordinated CI 39093070343 PASS with 13 distribution files /
  552 checks and nine live files / 389 checks. At credit release,
  the producer had submitted only 10 of 512 complete 4KiB chunks;
  Reader pending was 32,739 bytes (also the maximum sampled).
  This distinguishes an actual QUIC credit stall from an
  application-only callback delay. Producer blocks=257,
  native resumptions=257; Reader polling turns=708.
- The Reader pending count is only application-visible queued
  response body bytes. It does not include native nghttp3/QUIC
  buffers, kernel datagram queues, retransmissions, Perl allocator
  overhead, or full process RSS. This establishes actual
  application-driven QUIC receive credit withholding, NOT a
  whole-stack memory bound or published high-level Client pull API.

Further verified independent QUIC transmit-buffer observation:
- Net::QUIC::Connection has a public send_buffered_bytes() getter,
  counting Stream bytes retained for outgoing transmission until
  acknowledged. Unlike H3 Reader pending_bytes, it measures
  SEND-side QUIC retention. The fixture samples it after producer
  bursts and datagram processing plus at credit hold release.
- Upper test-only source bb891776d3aad4de3020c3f7e2f6ee273b11477f
  CI 39093371363 PASS: 13 distribution files / 552 checks,
  nine live TCP/QUIC files / 391 checks, benchmark smoke passed.
  Reader peak sampled 32,739 bytes; QUIC retained send-buffer
  at release 8,192 bytes and peak sampled 8,192 bytes.
  Producer only submitted 10/512 chunks during the credit hold,
  and completed afterward. Blocks=resumptions=257.
  QUIC and Reader buffers are two separate, sampled surfaces,
  NOT an aggregate memory measurement. The 8,192-byte value is
  per this fixture, not a general QUIC upper limit.
- This uses only public Net::QUIC instrumentation. No edits to
  Net::QUIC, HTTP3, Uniform or other protocol engines.

Remaining: native nghttp3 retained/provider buffers and process
RSS/copy instrumentation; several independently credit-blocked
H3 streams and larger concurrency stress; fair direct-H3 vs
unified Client benchmarking. No engine or read-only dependency
changes, main edits, merges, tags, releases or version bumps.

## Concurrent HTTP3 workload profiling continuation (2026-10-18)

Remote branch check on entry: upper feature 1aa49c88dd1652dc1fdf872f1fe8de0bb2d449c9;
H1 bb8349ef, H2 51fb1ad9, H3 721395e9. All four main baselines match
prior documented hashes, and Net::QUIC/Uniform are read-only.
Reviewed upper Handoff, design-handoff, IMPLEMENTATION and ENGINE-CONTRACTS,
engine handoffs, existing H3 benchmark and CI workflow.
No local checkout was supplied. Changes are connector-authored on the
explicit upper feature branch only; H1/H2/H3 source unchanged.

New opt-in bench/h3-workload-profile.pl adds a controlled-workload-oriented
comparison to existing serial bench/h3-client-vs-direct.pl. One reused
authenticated QUIC connection and same server/Net::QUIC::Driver for both
direct Unblock::HTTP3::Client and unified Unblock::HTTP::Client. A warmup
phase finishes completely before timed dispatch. Bounded concurrent
request windows (1..16), configurable buffered response body (1..1MiB),
alternating trial order, repeated trials. Measures request() inclusive
call time, end-to-end wall interval, per-completed-request p50/p95/p99
latency, per-process user+system CPU via Perl times, and sampled Linux
/proc/self/status VmRSS. Validates complete body and status for every
request. These are NOT allocation/copy counts, an allocator RSS high
water mark, or isolated server/client memory (both share one process).
Worker scheduling, cryptography and the shared CI runner inject noise;
no speedup/regression claim warranted without repeat controlled host.

Benchmark-only feature commit cbbca7182f9d6aa2721a01adf84cb765c0ea9098;
workflow smoke commit 49f2968e5296d8bfdc7fed1b94cae38a8b041a98
runs 30 measured/8 warmup requests x 2 rounds x concurrency 4 at
16KiB response, and 12/4 x 2 rounds x concurrency 2 at 256KiB.
Existing direct serial H3, H1/H2, and eleven live TCP/QUIC tests retained.
CI 39136691305 in progress at this checkpoint; inspect result, repair
only on approved feature branch as needed, and record measured outputs.
No versions, main, merges, tags or releases touched.

## Dynamic HTTP3 cancellation and direct benchmark verified (2026-10-18)

H3 native source e6c1cbb0e54b0dbe40ed6d29e5884e50983a3319
extends t/01-native with producer join, native discard, EOF and
repeated discard per-stream retained-byte accounting. Full H3
Linux Perl matrix CI 39133563818 PASS. This is a test-only engine
change beyond previously verified fair-share production code;
H3 interoperability source remains otherwise unchanged.

Upper CI 39133882442 PASS on source
9a507a5534c138e6eebe5d09ab9e6646c259ddb4:
552 distribution checks, eleven real TCP/QUIC files / 485 checks,
extra 128 KiB multi-reader 64 checks, extra 4 MiB 58 checks and
benchmark smoke PASS. New xt/linux-event-quic-join-cancel.t:
one authenticated QUIC socket, a held 1 MiB pull Reader,
a cancelled active producer (twice, idempotent), a late 512 KiB
streamed producer, and a separate fast response. Validated
client and server terminal cancellation, native discarded-body
counter zero, exactly-once response and matching SHA256,
producer write(false)/on_drain resumptions, bounded 4-write
deferred bursts, native per-stream/aggregate count reconciliation.
No production changes to upper Client/Server in this slice.

New opt-in bench/h3-client-vs-direct.pl directly compares
Unblock::HTTP3::Client against shared Unblock::HTTP::Client
using identical Net::QUIC::Driver transport, a shared upper
Server, local UDP/TLS and one outstanding small GET. A separate
warmup excludes handshake, run order alternates and script
reports completed-request interval and inclusive request()
time, NOT process memory or copies. Its first smoke failed
due a BENCHMARK callback-shape bug: direct on_complete($tx)
receives one argument, versus upper on_response($tx,$response).
Corrected benchmark source 10a6b57109f76ced416aa05b0343ef08615e9cb3.
Upper coordinated CI 39134487091 PASS including benchmark smoke;
552 distribution + 485 live + 64 + 58 extra checks still PASS.
30 measured GETs after 8 warmup on the shared runner produced
574 req/s direct and 542 req/s unified; direct/unified
mean request call times 237.41/309.59 us. One short run is NOT
a statistically controlled baseline, alloc/RSS measurement
or a defensible performance claim.

Final feature source docs followed tested benchmark source.
HTTP1/HTTP2 branches and all four main refs unchanged;
Net::QUIC and Uniform::HTTP read-only. No merge, release,
tag or version bump. Next: repeated controlled H3 direct
benchmark with realistic concurrent/body sizes and RSS,
copy/CPU instrumentation; then resume future HTTP/WebSocket
protocol integration milestones. Observe per-stream fair-share
producer scheduling as new streams join and cancel.

## HTTP3 dynamic stream join/cancellation continuation (2026-10-18)

Starting remote heads: upper 103c6714982aeb5a9bb547533039fcd70cf16d5d;
H1 bb8349efdc5cf55d7730b40d55eff665cc3a245c,
H2 51fb1ad9ef97ff7a4451b10d14a505df4d55fae4,
H3 da4789e588ff525fda1339002a88aab607752bfb.
All four main baselines unchanged. Approved design/handoff,
implementation/engine-contract docs and all three engine
handoffs reviewed. No read-only dependency modifications.

Native engine test-only source e6c1cbb0e54b0dbe40ed6d29e5884e50983a3319
extends H3 t/01-native with join, discard/cancellation simulation,
EOF and repeated discard per-stream retained-byte invariants;
full Perl matrix CI 39133563818 PASS. Existing HTTP3 producer
fair-share implementation unchanged.

New upper xt/linux-event-quic-join-cancel.t on the existing
real UDP/QUIC/TLS LinuxEvent fixture keeps one 1 MiB streamed
response's pull Reader uncredited, concurrently starts another
streaming producer, cancels that producer's client transaction
twice (idempotence), and then joins a 512 KiB response using
the same authenticated QUIC connection. An independent small
response proves multiplex isolation. It checks native aggregate
and per-stream accounting, cancellations, full payload SHA256,
once-only terminal outcomes, response end, write(false)/on_drain
and cooperative deferred producer bursts. A live test-only
source d97697e3f02063b7342247184b1a64343c336c4f
and upper CI source 9a507a5534c138e6eebe5d09ab9e6646c259ddb4
pin the native test commit and add xt to LinuxEvent workflow.

CI 39133882442 was in progress; do not call this live case
verified until its result has passed. Fix test bugs on upper
feature and production defects only in authorized H3 feature.
Do not edit main, Net::QUIC, Uniform, release, merge, tag or
bump versions. Continue with quantitative direct-H3
measurements after the dynamic lifecycle is green.

## Live H3 native per-stream retention reconciliation (2026-10-17)

Starting upper feature source a545a4ddecef5501e3392dcd3f4f3a4a56223efd,
with verified CI 39098422769. Engine HTTP3 tested source
96cf41e9378333fb4f7b48d89c8311c1dcf7cee7 remains pinned;
H1/H2 and all four main refs untouched. H3 full engine matrix and
interop previously passed. Only upper tests/CI/docs changed here.

The existing xt/linux-event-quic-multi-credit.t now samples the
internal H3 _Native streaming_retained_bytes_for_stream for each
of three live streamed server responses, reconciles their sum
against native connection streaming_retained_bytes, and records
the peaks. This is only native retained producer body bytes;
QUIC send retention and Reader receive pending remain distinct.
It does NOT claim aggregate RSS or kernel queue bounds.

Upper CI adds a third run with send_buffer_limit 131072 between
the original tight 8192 and isolation 4194304. Verified source
556d296392745b7ab16a31b7b213bcf62638aa6b,
LinuxEvent integration run 39098755460 PASSED:
552 distribution checks; 10 TCP/QUIC files / 455 checks at 8192;
an additional 64 checks at 131072; 58 checks at 4194304;
benchmark smoke checks passed, timing not a performance claim.
No per-stream accounting mismatches.

Observed native retained body peak (NOT a hard cap):
- limit=8192: 13618; per-stream observed peaks 5391,5397,9493;
  QUIC sampled send-retained peak 8192.
- limit=131072: 173406; per-stream peaks 47774,69551,133856;
  QUIC sampled send-retained peak 131072.
- limit=4194304: 3047511; per-stream peaks 1015837 each;
  QUIC sampled send-retained peak 3061953.
Per-stream PEAK values are observed at different times and MUST
NOT be summed as a simultaneous total. These values support the
documented accepted-whole-write soft budget (overshoot), NOT
a memory bound across QUIC, TLS, nghttp3 metadata, kernel or RSS.

Remaining: controlled throughput and latency baseline; peak RSS,
copy count and overhead measurements; fairness as streams join,
cancel or exit mid-write; large concurrency, overflow and body
discard accounting. Changes confined to authorized feature
branches. No main, merge, release, tag, version, read-only
dependency modification.

## Bounded shared HTTP3 producer fairness continuation (2026-10-17)

Starting source heads were upper b86aa43ea0b97a21faa1ac2f7d1866c3e1272992;
H1 bb8349ef, H2 51fb1ad9, H3 7bbca3ed.
All main refs verified unchanged. Reviewed all four upper approved docs
and all three engine handoffs; no local shell git checkout available.

New feature-branch-only HTTP3 native code tracks per-stream retained
body bytes and number of active unfinished native streaming producers
(HTTP3 source 96cf41e9378333fb4f7b48d89c8311c1dcf7cee7).
Its connection-level write(false) and on_drain policy compares each
producer's retained bytes with its share of send_buffer_limit instead
of allowing unrelated flow-control-blocked streams to suppress all
drain callbacks. Writes remain accepted in full even when returning
false; a single oversized write can exceed the advisory limit.
No Net::QUIC or Uniform changes; no public NativeABI change.

Upper xt/linux-event-quic-multi-credit.t now defaults to the previously
starving 8192-byte native buffer threshold, checks that production
stalls during the hold and each blocked producer receives drain
wakeup when its own Reader is released. A second mode retains the
large 4 MiB threshold for independent QUIC receive-credit isolation.
The CI workflow runs BOTH modes and pins the precise HTTP3 source.
Test commit 5a89a34d685fd7756a8479a4e39d4b303bd786b7;
workflow source commit 0786d84704c950ded3c307037c95086403bd93a1.
Engine source 96cf41e9378333fb4f7b48d89c8311c1dcf7cee7
passed full Perl matrix CI 39098239956; engine
interoperability 39098219785 passed the immediately prior
same production code. Upper CI 39098276763 first reproduced
all 1 MiB completions and per-producer drain resumptions with
send_buffer_limit 8192, but failed ONE test-only expectation
that all three Readers held initial bytes. slow2 was initially
empty because of QUIC stream scheduling, not because it received
any body data without credit. Initial test assertion corrected
to require a nonzero held aggregate, preserving each Reader's
window bound, sequential credit isolation, complete digest and
all producer resume assertions.

VERIFIED: upper test source a545a4ddecef5501e3392dcd3f4f3a4a56223efd,
CI 39098422769 PASS: 552 distribution checks, 453 live
TCP/QUIC checks over ten files with 8192 native send_buffer_limit,
plus a separate 4 MiB multi-reader run with 56 PASS checks.
Every slow producer completed all 256 accepted chunks once,
with matching per-producer on_drain/resume counts, and a fast
stream completed before any slow Reader was released.
QUIC sampled retained send bytes: 8192 peak at the tight
budget and 3061953 at the intentionally high threshold.
These are NOT universal hard memory bounds or speed benchmarks.
The former deadlock is now resolved for this measured workload.

No H1/H2, Net::QUIC, Uniform, main, version, tag,
merge or release changes. Remaining: memory and copy
instrumentation, additional concurrent producers and load,
direct native vs unified Client controlled benchmarks.

Remaining after CI: per-stream native retained measurement under load,
large concurrent producers, accounting invariants on reset/discard,
whole-process RSS and copies, direct-H3 baseline and memory bounds.
No source changes to H1/H2 or read-only deps; no main, merge, tag,
release or version changes.

## Multiple simultaneous H3 receive-credit holds (2026-10-17)

Starting upper ref 56aa303dc959fe1130708304b7313efcf0ba3670;
engine feature heads: H1 bb8349ef, H2 51fb1ad9, H3 b093bcf8.
All main refs checked unchanged against saved baselines. Local git
checkout/fetch unavailable (DNS); GitHub connector publishes explicit
feature-branch changes. The preceding credit experiment passed upper CI
39093371363 (552 distribution / 391 live checks).

Next stress slice is test-only. New xt/linux-event-quic-multi-credit.t
uses one real authenticated QUIC connection, three independent 1 MiB
native H3 streamed responses with pull Body::Reader and a fourth small
response. Each slow Reader advertises a 32 KiB stream receive window;
QUIC connection_window is 256 KiB. Withhold all Reader consumption for
0.5 seconds. Assert the fast stream completes, each slow producer stalls
before 256 chunks, and each Reader pending byte count is within its
advertised stream window. Then release exactly one Reader at a time and
assert the other Readers remain unfinished with no credited chunks.
Verify each final digest, length, once-only terminal notification,
accepted-byte writes, on_drain resumption, and bounded producer bursts.
These are sampled specific buffer surfaces, not aggregate process
memory or evidence of zero-copy.

Feature test was first published at 9ce6c64db67a99cf1d4e2aace9d8bb3c04366c06
and added to the workflow at d7e75d91b4ac7e458472da2b1d3feb7e8e9a7dd6.
Initial CI 39095627619 FAILED only the new 45s multi-reader watchdog.
A correct nghttp3 flow-control block/unblock bridge was added on HTTP3
feature source 14eaaf2f94173650b830799a2f43fca0c77ab0a1;
HTTP3 matrix 39095993708 and interop 39095993713 PASSED.
However upper 39096018997 still failed the multi-reader watchdog.
Raising global H3 send_buffer_limit to 131072 still deadlocked upper
39096310032: the slow0 Reader got 90112 bytes but could not finish.
The aggregate native retained-body threshold is shared among all streams,
and other blocked producers may consume it; this is a distinct
aggregate-producer fairness issue, NOT resolved by nghttp3 stream scheduling.

Final multi-Reader fixture isolates independent RECEIVE credit from
aggregate producer backpressure: H3 send_buffer_limit is 4 MiB, exceeding
the three 1 MiB streamed bodies. It deliberately does NOT assert a
producer write(false) or on_drain. Existing single-Reader test with
send_buffer_limit 8192 still exercises real producer backpressure, and
the other H3 and H1/H2 tests remain in the workflow. One fast request
completed while all three Readers withheld credit; Readers were then
drained one at a time, with the other streams still incomplete and
uncredited, and all final digests and lifecycle callbacks verified.

VERIFIED: upper source/test commit ceeca6638e6faf6f2561089fcaaf3d5ad0c626d7,
CI run 39096607845 PASS: 13 distribution files / 552 checks;
10 live TCP/QUIC files / 446 checks; benchmark smoke PASS.
Sampled three Reader pending counts at hold: 32739 bytes each
(advertised per-stream window 32768); maximum sampled QUIC transmit
retention 3061953 bytes for this intentionally large-buffer fixture.
Producers had all submitted 256 chunks each by the hold; that does not
show producer stall or memory efficiency. No total process RSS/native
provider memory bound has been established.

The only engine production changes in this slice are HTTP3 native
nghttp3 block/unblock handoff and output scheduling; HTTP1/HTTP2,
Net::QUIC and Uniform remain unchanged. Main, versions, tags, merges
and releases remain untouched.

NEXT: solve aggregate producer fairness without unlimited buffering:
design per-stream retained-byte observability and producer readiness
under a bounded global send budget; regression-test the original
tiny-global-limit multi-reader case rather than silently weakening it.
Also native nghttp3/provider retained buffers, process RSS and copy
instrumentation, broader multi-origin/QUIC stress and direct H3 vs
unified Client benchmarks.

## Current implementation

- Server is a reusable definition with shared protocol policy. Attachments
  return real engine objects; frameworks retain sockets and timers.
- on_headers maps directly to engine on_request. Application on_request maps
  directly to engine on_request_end, after successful body/trailer completion.
- Buffered by default, 1 MiB per enabled protocol. Tune the positive
  max_buffered_body_bytes in its protocol hash; receive_body is managed.
- Register tx->on_data at headers to select streaming. The engine owns the
  receive buffer; the upper layer has no per-chunk forwarding or accumulator.
- tx->on_finish observes complete/error/cancelled once, after normal/error
  callbacks. Intentional cancellation does not manufacture an error.
- Actual transaction and Uniform message identities remain intact; no wrappers,
  reblessing, injected methods, or required XS in this distribution.
- Old upper on_body/on_request_end constructor options are removed, no aliases.
- Attachment checks on_data/on_finish capabilities and rejects released engines.
- H1/H2 add bounded receive buffers; H3 reuses its buffer/Reader. Standalone
  defaults remain H1/H2 stream and H3 buffered, with a 64 MiB buffered limit.
- Empty frozen messages carry an empty string from construction. Public native
  ABI layouts and discovery paths remain unchanged.
- H3 overflow resets only its stream. Rejected streams still process QUIC
  reset/close state. STOP_SENDING already credits discarded receive bytes;
  Reader cleanup and queued native events avoid crediting them twice.

## Published and tested source commits

The integration workflow pins these exact commits:

- HTTP1: 82dfc4bf691001aff50f96bb7a92e6fce3fbb229
- HTTP2: 90639bf52394098296be4115e5485606ba6d7f92
- HTTP3: 3824e7b91012f2a73143ca46eb0d077db6d1af6a
- Net::QUIC (unchanged): 566366819b21c30e449bf13f55ec1d6ebfc5de64

Engine branch heads include subsequent handoff-only commits. Do not replace
these tested source pins just to match a documentation-only head.
Upper source/test checkpoint: 95a3fb25363eb8c8b5cf948f8eb1a8124b5ca9e6.
All remote trees were verified identical to the prepared local trees.

## CI results

- HTTP1 test 39058702399: PASS on Linux Perl 5.16/latest, macOS latest,
  Windows Strawberry 5.40; distribution/POD checks passed.
  Framework examples 39058702329: PASS.
- HTTP2 test 39058704851: PASS on the same platform matrix, including
  distribution, installed NativeABI and optional examples checks.
  Interoperability 39058704842: PASS.
- HTTP3 test 39059118633: PASS on Perl 5.20/5.28/5.36/5.44,
  26 files / 942 top-level tests/subtests. Perl 5.44 passed distcheck,
  disttest, installed NativeABI/header checks and POD syntax.
  Interoperability 39059118732: PASS (quic-go and public H3 servers).
- Upper initial integration 39058779436: PASS at 71b0c8ac9f1f63a5d53b5edd3f2506659b0c0ed6.
  Final run 39059172525 at the source checkpoint above: PASS.
  The strengthened QUIC test sends a POST and checks complete buffered body,
  identity, freeze and callback order. TCP exercises H1 and H2.

Run URLs: https://github.com/haxmeister/REPOSITORY/actions/runs/RUN_ID
Use the matching repository name above. The ordinary Server receive/lifecycle
milestone is verified. Later design milestones remain unimplemented.

Earlier H3 runs exposed and fixed reset bookkeeping, double receive credit,
stale connection-wide overflow expectations, and recursive object comparison
in new tests. Upper run 39058944806 failed before tests during Alien::nghttp2
installation. The workflow now installs system nghttp2 development files and
prints cpanm's build log on failure. Do not mistake those superseded failures
for current results.

## Local reproduction and limits

Local Perl 5.38.2: H1 full suite 36 files / 320 checks; H2 full suite
30 files / 525 checks; upper suite 6 files / 182 checks; all PASS.
Upper t/14 uses real H1/H2 engines, other upper tests use doubles.
H3 native/Reader/terminal tests: 3 files / 92 checks PASS locally.
Full H3/live QUIC validation was done in GitHub CI, not locally.

H1 uses deps/Uniform-HTTP/lib. H2 local build uses the actual system nghttp2
1.59.0 and matching headers through /tmp/http2-system-Makefile.PL.
H3 local build uses deps/nghttp3 development source 1.18.90 through
/tmp/http3-source-Makefile.PL. Repository Makefile.PL files are unchanged.
CI validates normal released Alien/Net::QUIC/Uniform dependencies.

From upper, run prove -lr t with PERL5LIB containing:
  ../deps/Uniform-HTTP/lib
  ../perl-Unblock-HTTP1/blib/lib
  ../perl-Unblock-HTTP1/blib/arch
  ../perl-Unblock-HTTP2/blib/lib
  ../perl-Unblock-HTTP2/blib/arch

After engine source edits, run make before prove -b so blib is current.
See each engine handoff for further local details. deps checkouts are build
and inspection inputs only; never publish modifications there.

## Next steps

1. Ordinary Server milestone is complete. Upper run 39059172525 passed the
   182 distribution checks and 15 live TCP/QUIC checks.
2. Preserve this milestone on feature branches, with no release or merge.
3. First Client factories/pooling passes CI run 39062105591, and same-host
   authenticated Alt-Svc + pre-dispatch fallback passes CI 39062960467
   (316 distribution checks and 15 live tests). Remaining: timeout policy,
   network change/cache invalidation, retries only with verifiable safe
   eligibility, peer-aware pool capacity, and wider live pool stress tests.
   Optional per-request deadlines and cancellable/stale connection attempts
   pass CI 39064100968 (371 distribution and 17 live checks).
   H1 terminal callback reentrancy is also CI-verified in run
   39064232198 (375 distribution / 17 live checks). Next milestones:
   H3 peer-credit readiness notification, broader multiorigin live
   stress, pool idle eviction and conservative transport-change handling.
4. Later: WebSocket transitions/permissions, transaction construction hooks,
   H1 successor-consumer routing, H2/H3 stream composition and pause/resume.
   The optional LinuxEvent adapter is currently server-only.
5. Stress tests, direct-engine benchmarks and final application/adapter docs
   precede release consideration. No speedup or zero-copy claim is established.

## Main baselines (unchanged locally and remotely)

- Upper: ad8ed8989a6c8fd9abd934f911a184116152be67
- HTTP1: fad447784ff00a43fea8cbb3d4f7520f872bcd52
- HTTP2: 7d705dd6408c032e65dd29aa94582bccfaca0925
- HTTP3: 97ef0048be212af34b21a7e1a65b3294f4d34b4c

Shell git fetch works. Publication uses connected GitHub create_tree,
create_commit and create_branch/update_ref tools; shell push lacked credentials.
Tool-created commits have different IDs. Verify the tree, update with expected
parent SHA and force false, fetch the explicit feature refspec, then synchronize
local history only after verifying clean worktree and identical remote trees.
Never force-push or update main.
