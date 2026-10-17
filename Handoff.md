# Unblock::HTTP implementation handoff

Updated: 2026-10-17
Repository: haxmeister/perl-Unblock-HTTP
Branch: feature/high-level-client-server
Status: Server, Client pool and authenticated Alt-Svc slices CI verified.

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
