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
