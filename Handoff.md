## Verified automatic 16/32 concurrent H3 memory guards (2026-10-18)

Primary upper Linux::Event CI 39176739238 PASS using **published**
Net::QUIC 0.05 and feature H3 engine. Distinct optional QUIC-feature
diagnostic workflow 39176739215 also PASS. All upper distribution,
live TCP/QUIC, Reader/producer/flow control and ordinary benchmark
smokes remained green.

The new opt-in UNBLOCK_H3_PROFILE_ASSERT_BOUNDED=1 guard ran for
BOTH 2048-measured, 128-warmup, two-round direct/unified 16-concurrent
and 32-concurrent, alternating 4096/16384-byte buffer workloads.
Both guard invocations completed without error. At each 256-completion
checkpoint, ready_tx stayed <= concurrency+64, live engine tx <=
concurrency+1, and private memory grew <= 8192 KiB from start of
measured phase, with exact status/body/callback validation preserved.
This catches the earlier callback notification / completed-Transaction
retention pattern while leaving intentionally strong pull-only queues
alone. It is a workload-specific resource REGRESSION GATE, NOT a
throughput/latency benchmark or a byte-copy counter.

Primary guarded 32-concurrency results: unified private KiB R1
7924->7968, R2 7860->7972; direct R1 6788->6940, R2
6756->6808. Final ready_tx=2 and engine tx=1 (terminal callback)
for both unified rounds. RSS/PSS also stayed bounded. The
ungarded 32-run 39176260513 had unified private memory R1
7744->7900, R2 7844->7860, ready_tx throughout 2..13.
Do not compare throughput across CI runners as stable speedup.

Minimal weak origin ownership change upper 945734c was independently
verified by primary CI 39175957247. Current upper feature source
d5e3026 adds stronger regression coverage, not new public APIs.
No main, merges, tags, releases, version bumps, Net::QUIC changes,
or HTTP1/2/3 engine edits. HTTP3 0.13 stays unreleased. Future
performance work should use a controlled repeatable dedicated host;
no native allocation/copy rates established.

## Automatic HTTP3 bounded-memory regression guard (2026-10-18)

Sustained 32-inflight real-QUIC test in primary published Net::QUIC
0.05 workflow 39176260513 PASS; optional separate QUIC feature
39176260525 PASS. Both include full upper tests and live socket
stress. Compared with the original 16-inflight sustained run:
128 warmup, 2048 measured, two independent client/server rounds,
alternating 4096/16384-byte buffered responses, SHA/body and
exactly-once callbacks. At 32: unified private memory KiB round 1
7744->7900, round 2 7844->7860; direct 6744->6788 and
6604->6716. Unified ready_transactions slots every 256 completions
stay 2..13, final tx registry=1 during terminal callback, RSS/PSS
nearly flat. This corroborates bounded retention under the largest
configured 32 H3 streams per pooled connection, not a native
alloc/copy measurement.

This commit enforces opt-in regression assertions in
bench/h3-workload-profile.pl with
UNBLOCK_H3_PROFILE_ASSERT_BOUNDED=1.
Only for callback-only 4/16 KiB CI with CHECKPOINT_EVERY and
REGISTRY enabled: at each sample ready_tx <= concurrency+64,
engine active tx <= concurrency+1, private growth <= 8192 KiB
compared with pre-measurement warmup. Catch reintroduction of
previous approx 80 MiB linear leak without a timing threshold
or restricting legitimate pull-only consumers. Diagnostic values
are not general guarantees for arbitrary payload sizes.

Previous private weak-origin lifetime fix upper 945734c PASSED
full published QUIC-0.05 upper CI 39175957247 and independent
diagnostic 39175957301. No main, merge, tag, release, version
bump, HTTP engine change or Net::QUIC source change. This guard
must be verified by next primary CI before claiming green.
HTTP3 0.13 still unreleased.

## Sustained callback memory verification at 32 H3 concurrent requests (2026-10-18)

The original memory regression was fixed and measured at 16
simultaneous requests; the real QUIC profiler already supports 32
but previous 32-concurrent CI usage only sent 64 measured requests.
This feature CI change adds the same long (128 warmup + 2048
measured, two rounds) real QUIC direct versus unified memory/registry
test at 32 outstanding requests, 4/16 KiB alternating buffered
responses, checkpoints every 256 completions, pinned to published
Net::QUIC 0.05, with body/status/callback validation and 180s
watchdog. The per-connection aggregate receive window remains
1 MiB, larger than the 32*16KiB in-flight buffered wave; this is
NOT the 12/16-stream withheld-Reader starvation test (preserved).

Purpose: confirm the fix bounds Transaction count,
ready_transactions length, RSS/PSS/private memory, and callback
lifetimes at the configured max_streams_per_connection=32, rather
than assuming the 16-stream measurements generalize. No native
copy counters added; this CI job is NOT a performance gate.
As of this change the 32 sustained profile results are pending.
Feature main, Net::QUIC released 0.05, sibling engines, versions
and releases remain untouched.

## Completed handle must not own the origin pool (2026-10-18)

Following the passing unified HTTP3 memory and constructor-path work,
a separate avoidable retention path was found: `_ClientOperation->new`
created both a weak Client reference and a STRONG `origin` pool
reference. A caller intentionally retaining a completed request handle
therefore inadvertently kept the origin pool, unrelated connections
and their QUIC/TCP state alive even after dropping the Client. The
public contract guarantees that an intentionally retained handle
keeps its **real engine Transaction**, not the other sessions in that
pool.

The minimal ownership change makes the **private** `origin` reference
weak at operation construction. The Client itself owns the pools,
queued operations live in the pool's pending array, and active
operations are held in the Client's active registry. A pending timer
also holds the Client while active. Thus this change removes an
unnecessary owner without callbacks, hot-path allocations, structural
API change, or post-completion cleanup requiring tricky reentrancy.
The op's `request`, `transaction()`, terminal/error/cancel state and
callbacks behave as before. No public method accesses the private
origin pointer.

The extended t/22-client-operation-lifetime.t tests all H1/H2/H3
mock engines: keep completed operation handle, drop Client/pool/engine,
assert pool reclaimed and actual Transaction still reachable and
terminal. Existing tests exercise queued, pending, timer, late
callback, credit and cancellation lifetime behavior. Check PRIMARY
published Net::QUIC 0.05 full Linux::Event CI plus the separate
QUIC-feature diagnostic, and do not claim a pass before the run
completes. This is a bounded-retention fix, not an actual native
allocation/copy-count measurement.

No main, merge, tag, release, version bump, Net::QUIC, HTTP1/2/3
engine changes; upper feature branch only. HTTP3 0.13 remains
unreleased.

## Published-Net::QUIC 0.05 request constructor breakdown complete (2026-10-18)

Feature code 36a013195e633d33ef8b59e8379f7c48753a3685 PASSED
complete upper primary real-QUIC integration GitHub Actions
39174909939 against **published CPAN Net::QUIC 0.05**; optional
Net::QUIC feature integration 39174909923 PASS. Both run unchanged
live TCP/QUIC stress, lifetime tests and published-dependency profiler.
Upper source 34a3070f H3-only Alt-Svc callback cleanup also PASS
primary full suite 39174722982 and QUIC-feature diagnostic 39174722889.

The benchmark-only `UNBLOCK_H3_DISPATCH_SPLIT=1` phase now intercepts
URI->new, Uniform::HTTP::Request->new and _ClientOperation->new on
the real upper Client with a fake no-network HTTP3 engine. Primary
CI 39174909939 reported in us/request over 3000 x 3 rounds:
- request() 74.392 / 74.790 / 74.245
- URI constructor 10.151 / 10.109 / 9.990
- Uniform request constructor 21.453 / 21.600 / 21.418
- operation constructor 2.217 / 2.246 / 2.200
- other outside _dispatch (residual) 30.511 / 30.631 / 30.485
- _dispatch (including fake request) 10.059 / 10.204 / 10.153
- mock engine request 2.010 / 2.015 / 1.991.

These INSTRUMENTED timings are not equivalent to the same benchmark's
unmodified loop totals (direct_mock median 16.583us,
unified_mock median 82.278us on that runner), nor to the real
QUIC 2048-request baseline. Constructor timings are inclusive
and probe calls introduce measurement overhead. This identifies
URI + Uniform construction as sizable, with nontrivial remaining
validation/pool/callback work; no single high-ROI fast-path rewrite
is yet established. Do NOT weaken URI validation, drop Uniform
canonical types, or add a new abstraction on the strength of
hosted CI numbers. Follow-up: repeat on a quiet controlled machine,
isolate realistic application request patterns and consider a
narrow change only if a stable end-to-end benefit is demonstrated.

All existing bounds on completed HTTP3 Transaction retention hold;
no native payload copy/alloc counts have been measured.
Main refs, HTTP1/HTTP2/HTTP3 engine, Net::QUIC 0.05, versions,
tags and releases remain untouched. HTTP3 0.13 is unreleased.
No release audit requested or begun.

## Request-path constructor cost instrumentation (2026-10-18)

CPU-only mock H3 diagnostic at upper 92d9c1e CI 39173943511 PASS
published Net::QUIC 0.05 and 39173943480 PASS QUIC feature. Primary
direct_mock median 15.917 us, unified_mock median 55.054 us;
diagnostic-feature run direct 9.432, unified 31.267 us. Large runner
variance makes these *diagnostic* only; the ratio is NOT real H3
throughput. Existing real workload is still the end-to-end signal.

Primary published Net::QUIC 0.05 CI 39174402639 PASS first phase split:
CLOCK-INSTRUMENTED unified request_us 47.627/47.523/47.455;
outside_dispatch_us 41.133/41.041/41.020;
dispatch_us 6.494/6.483/6.435;
fake_engine_us 1.382/1.386/1.361, microseconds per request.
Most request() CPU is outside _dispatch; the split itself changes
timings and should NOT be combined with uninstrumented totals.
The current bench-only commit 36a01319 extends that instrumented split
to URI->new, Uniform::HTTP::Request->new, _ClientOperation->new
and the residual. New upper CI 39174909939 / 39174909923 running.
Benchmark docs updated in docs/PERFORMANCE.md. Do not optimize native
byte copies or claim body throughput gains based on this CPU-only fake.

Separately, upper 34a3070f H3-only Alt-Svc no-observer cleanup
is green on QUIC diagnostic CI 39174722889; primary published
Net::QUIC 0.05 integration 39174722982 is pending at this point.
Mixed TCP/H3 Alt-Svc discovery is preserved; pure H3 buffered and
streaming callbacks now have explicit tests.

No main changes, merges, tags, releases, version bumps, Net::QUIC or
HTTP engine edits. Continue checking the published 0.05 workflow,
evaluate breakdown, and decide whether targeted request-path work is
justified. HTTP3 0.13 remains unreleased.

## H3-only Alt-Svc callback fast-path cleanup (2026-10-18)

After CPU-only profiling showed repeated request setup/dispatch overhead,
the upper Client feature was narrowly changed to avoid installing an
Alt-Svc on_response observer for an H3-only policy. That observer was
unusable: the Alt-Svc cache can only select alternatives for later
TCP-first requests, and a Client configured with only H3 never issues
TCP-first requests. Mixed H1/H2+H3 policies KEEP the observer.
H3-only streaming applications still receive their on_response header
callback directly, and buffered application on_response remains in
on_complete. t/15-client-pool.t adds buffered and streaming H3-only
response/finish ordering checks and the absent unneeded observer check.

This is an application-request/response-header path optimization only,
not a per-byte copy change. No public API, engine, QUIC, ABI or version
change. Real-QUIC, established callback/pull memory, release-stress
and interop tests must all remain green. Benchmark A/B across hosted
runs is noisy; do not advertise an overhead improvement without
matched repeated measurement. This implementation is experimental on
the authorized upper feature branch only.

## Instrumented split of ready Client dispatch (2026-10-18)

First completed CPU-only diagnostic (optional Net::QUIC feature workflow
39173943480 PASS, bench/client-dispatch-profile.pl 3000 x 3):
direct minimal fake H3 engine median 9.432 us/cycle, real unified
Client + same fake H3 engine median 31.267 us/cycle. Real URI-only
median 7.388 us and real Uniform::HTTP::Request-only 7.813 us in
adjacent benchmark, combined URI+Uniform 15.447 us. A mock 3.315x
ratio is NOT real QUIC HTTP3 overhead; it deliberately removes
TLS/UDP/QUIC and body processing and direct case skips URI/pool
policy work. It does show setup/scheduling in the real unified
Client is worth breaking down. The published Net::QUIC 0.05
primary CI 39173943511 was running when this experiment began.

This commit opts the primary workflow into an additional
UNBLOCK_H3_DISPATCH_SPLIT=1 phase timer for the already-added
CPU-only mock engine benchmark. It intercepts _dispatch and the
fake engine request in a strictly isolated benchmark script
to obtain request(), dispatch(), fake engine request(), and
subtraction residuals. Instrumentation overhead is explicit,
values approximate, and no production method or network/ABI
is changed. See docs/PERFORMANCE.md. Check both workflows'
CI outcomes and report split times. Only after repeatable
measurement consider narrowing unnecessary HTTP3-only
callback/Alt-Svc overhead; do not sacrifice generic URLs,
operation lifecycle, or H1/H2 semantics.

No merges, tags, release, version bump, main changes or
modifications to Net::QUIC/HTTP1/HTTP2/HTTP3.

## CPU-only request/dispatch profiling experiment (2026-10-18)

Resumed after successful bounded-memory fix and three-round
uninstrumented real H3 baseline. Current primary upper branch was
19a53fb088fc6070b5a5279ee5ed77f2a24840c1.
New bench/client-dispatch-profile.pl compares canonical Uniform
request + mock direct HTTP3 request/callback finish against the real
upper Client ready-connection, URL parsing, operation registration,
callback and dispatch path backed by the SAME lightweight fake engine.
No QUIC, UDP, TLS, native payload or body reads. This is a diagnostic
CPU-only control, **not** an end-to-end HTTP3 throughput claim. It
asserts callback counts, terminal operations, no pending/deferred
work and empty active-operation registry after each mode.

Both upper workflows now run 3000 requests x 3 rounds of this
instrument after bench/request-setup.pl; inspect CI before interpreting
any numbers. Existing memory/real-QUIC 2048 profiles, standalone
HTTP3 matrix/interoperability and stress fixtures are preserved.
The real QUIC hosted baseline had direct median 1083.1 requests/s,
unified 994.3, 1.089 wall ratio (single hosted run only), and
separately request_us about 136 vs 190-194. The CPU-only control
should determine whether setup/dispatch is a sensible place for an
optimization experiment, but not assign costs to native copies.
No production code, Net::QUIC, HTTP1, HTTP2, main, versions, tags
or release changes. Next steps: verify CI smoke, evaluate results,
then only optimize paths supported by measurements.

## Completed sustained HTTP3 uninstrumented throughput/latency follow-up (2026-10-18)

Upper feature 0f5cb2bfb545c0d9308888a469c54bb3b25bc55c verified
with published CPAN Net::QUIC 0.05 in **full upper integration**
GitHub Actions 39172590547 PASS. Companion unreleased Net::QUIC
feature diagnostic 39172590469 PASS, NOT a required release dependency.
Both workflows completed distribution tests, real TCP/QUIC/held-Reader
stress, checkpointed 2048 memory profile, sustained uninstrumented
2048-profile, and the short benchmark smoke stage.

New UNINSTRUMENTED matched same-connection H3 profile:
2048 measured requests after 128 warmup, 3 fresh isolated rounds for
each client mode, 16 concurrent GET requests, alternating 4096/16384
byte buffered responses, full body/status/callback assertions.
Direct R1/R2/R3: 1081.6/1091.7/1083.1 req/s; setup
136.30/136.22/135.92 us. Unified R1/R2/R3:
998.5/985.8/994.3 req/s; setup 190.52/194.35/189.95 us.
Median wall direct 1.8908s, unified 2.0598s (ratio 1.089).
Direct p50 latency 8848.9/8769.0/8759.0 us; unified
9366.0/8923.1/8789.1 us. Full p50/p95/p99 and exact
setup values now in docs/PERFORMANCE.md, with provenance and caveats.

The 1.089 is a hosted-runner DESCRIPTIVE ratio, NOT a reliable
performance or overhead claim; request_us is synchronous setup,
not network RTT, and the one-host CI is affected by scheduler/TLS/UDP.
No allocation event counts, native-copy counts, or memcpy volumes
were measured. Do not infer native memory overhead from RSS or
wire bytes. Further copy optimization should require instrumenting
specified copy sites in a carefully scoped build after establishing
a repeatable dedicated-host baseline.

The independently VERIFIED retention tests from prior upper
39172126688 remain PASS at this source: ready_tx 2..3 and unified
private memory 7.3..7.5 MiB rather than 2176 stale slots and ~95 MiB.
HTTP3 four-version matrix 39172069382 and interop 39172069428 PASS
against production HTTP3 source 5e0d496b. Additional test-only HTTP3
t/27 moved-weak-slot assertions at 27eae747 PASS four-version matrix
39172771475; engine production source unchanged. H3 Handoff also
updated (latest docs/test head 6687bcef). All main branches, Net::QUIC,
HTTP1/HTTP2 untouched. No merges/releases/tags/version bumps.
Unblock::HTTP3 0.13 is still UNRELEASED.

## Verified bounded unified HTTP3 memory; uninstrumented profile follow-up (2026-10-18)

PRIMARY upper feature 9da9a02fc562259003aa9ac446fe7159bca73aeb
plus HTTP3 feature 5e0d496bb52331670edc9850d6fa417d984d0e67
PASS upper published Net::QUIC 0.05 full integration GitHub Actions
39172126688, including 2048-request/128-warmup two-round 16-inflight
profile, complete Linux::Event TCP/QUIC and held Reader stress, upper
distribution tests and short benchmark smokes. Separate diagnostic
using standalone unreleased Net::QUIC feature PASS upper 39172126759,
but the HTTP3 candidate requires *only published Net::QUIC 0.05*.
Standalone H3 Linux Perl 5.20/5.28/5.36/5.44 matrix 39172069382 PASS,
independent quic-go/public-server interoperability 39172069428 PASS.

All 256-request checkpoints in both rounds show unified ready_tx=2..3
(vs 2176 stale array slots before final compaction) and unified active
tx=1..16, streams=7..22, ready_info=0, QUIC buffered TX=0..240 bytes.
Direct ready_tx=1..5. Private client KiB direct R1 6340->6416, R2
6292->6364; unified R1 7356->7480, R2 7396->7436. RSS/PSS also
nearly flat. This RESOLVES completed-Transaction cycle and weak queue
stale-slot growth in callback-based sustained same-connection workload.
Caller-retained operations still own actual completed Transaction;
pull-only notification retention remains strong by contract.

The first HTTP3 weak compaction 3f194... was broken (Perl grep
accidentally strengthens weak references); it was replaced at 5e0d49
by in-place weak-preserving compaction tested explicitly in t/27.
Do NOT use initial 39171819978 failing matrix or intermediate
39171896551 memory profile as evidence of final fix.

This commit adds a sustained **uninstrumented** matched 2048/128/3/16
4096,16384-byte diagnostic to the PRIMARY upper integration workflow
and records final memory/checkpoint metrics in docs/PERFORMANCE.md.
Check new CI and compare within-trial direct/unified throughput,
p50/p95/p99/request_us, but hosted runner timing is NOT an overhead
benchmark. Do not infer native allocation or copy counts from memory
or wire counters. No main merges/tags/releases/version changes,
Net::QUIC modifications or HTTP1/2 edits. HTTP3 0.13 is still
unreleased; remaining work is optional controlled dedicated-host
profiling and precise native copy instrumentation if justified.

## Discard invalid grep-based HTTP3 weak pruning candidate (2026-10-18)

The first periodic HTTP3 weak-slot cleanup 3f194ec51b19de73a986612763954c4184cb21d6
FAILED standalone Linux matrix 39171819978 because grep-copying a weak
reference promotes it to strong. A new t/27 live-old-head regression
detected this. Do not use that candidate; any memory profile under its
source would be invalid for the retention fix.

HTTP3 feature 5e0d496bb52331670edc9850d6fa417d984d0e67 instead
uses an in-place linear sweep that preserves each live entry's weakness
while removing expired slots; the test also verifies isweak() after
compaction. Updated BOTH upper workflow pins to the corrected feature.
Standalone HTTP3 four-version matrix 39172069382 and interoperability
39172069428 are running. Upper CI must revalidate 2048-request profiler,
all checkpoints, ready_tx, private/PSS/RSS, active tx and full stress
under published Net::QUIC 0.05. Do not report weak-queue cleanup as
validated until those jobs finish. Keep main, releases and Net::QUIC
untouched.

## Unified completed-operation ownership and H3 weak-queue compaction (2026-10-18)

The suspected unified Client lifecycle cycle was independently reproduced
by new t/22-client-operation-lifetime.t in test-only upper commit
d7b5d1fc5beee1ca96539e892732f9579b3edcd1, with 9 / 43 new
assertions failing across mocked HTTP1/2/3. The corrected upper Client
commit 9f47d2b4ea8370f5c215261cbe9474bebaae2801 uses a Client-owned
strong active_operations registry; H3/H2/H1 Transaction callbacks capture
weak references back to operation/client/pool/connection. Terminal on_finish
removes ownership after user callbacks, preserving real transaction()
identity for caller-retained operations and exactly-once completion.
H3 stream-credit refusals and engine exceptions clear the active slot.
No body hot-path wrapper, engine ABI, or Net::QUIC change.

The upper PRIMARY published Net::QUIC 0.05 run 39171144266 PASS
(distribution tests, all real socket and Reader stress including 10s hold,
2048-request direct/unified profiler, benchmark smokes). Upper separate
unreleased QUIC feature diagnostic 39171144260 PASS. The 2048 workload
(128 warmup, 16 in flight, 4096/16384-byte response alternation, 2
isolated rounds) shows unified private memory 7332->7520 KiB in round 1
and 7420->7524 KiB in round 2; direct 6444->6476 and 6276->6368 KiB.
This resolves the previously observed ~95 MiB unified retained footprint;
RSS and PSS also remain near-flat. CI timings are descriptive only.

The same profiler exposed residual ready_transactions array LENGTH 2176
for unified mode, even with bounded memory: weak entries expired behind
an old still-live weak head, preventing head-only pruning. HTTP3 feature
3f194ec51b19de73a986612763954c4184cb21d6 adds a periodic 64-callback
insertion expired-slot compaction for both transaction and informational
queues, and t/27 tests a live old weak head + 512 expired weak entries
+ a strong pull-only entry, validating FIFO and bounded weak tail.
The upper CI workflow feature pins NOW point to that HTTP3 commit. The
HTTP3 standalone four-Perl matrix 39171819978 and interop 39171819937
have been triggered and must be checked. Run the new upper full workflow
against CPAN Net::QUIC 0.05 and VERIFY ready_tx stays bounded at every
256-completion checkpoint, as well as memory, private/PSS/RSS, tx count,
and 2048 completion integrity in both direct/unified rounds.

No main changes, merge, tag, release, version bump, branch deletion, or
Net::QUIC / HTTP1 / HTTP2 source modification. HTTP3 0.13 remains an
unreleased candidate. Measure workload trends before claiming compaction
fully verified; still no allocation/copy rate measurement.

## Retention correction under full real-QUIC integration (2026-10-18)

The isolated 2048-request profiler confirmed ready_transactions grew by
exactly 2176 entries (128 warmup plus 2048 measured) in both direct and
unified callback mode, while live stream/transaction registries stayed
bounded around the 16-inflight limit. PSS/private growth was substantial
and approximately linear. This is a duplicate, strongly retained pull
notification queue, not the active-stream map.

Unblock::HTTP3 feature 91aaced500e6aaf2eba9818ad192398c9cf62f15
now weakly queues callback-owned transactions (including server callbacks),
preserves strongly queued pull-only transactions and prunes expired slots.
t/27 provides isolated weak/strong queue lifetime checks; t/04 checks the
real callback-delivered client notification and mixed server callback/pull
identity. The standalone H3 pre-test-source CI at c484625b succeeded
all four Linux Perl jobs and interoperability. Updated H3 final test
run and the UPPER full real-QUIC integration still need verification.

The upper two separate integration workflows now pin that H3 feature.
The primary workflow continues using published CPAN Net::QUIC 0.05;
the independent QUIC-feature diagnostic workflow uses the clean generic
MAX_DATA change. Both rerun 2048 callback-mode requests with opt-in
checkpoint and registry counters. Compare private/PSS trend and ready_tx
counts to baseline CI 39164948301 before claiming retention fixed.
Do NOT merge, bump, tag or release yet.

## Prolonged independently held HTTP3 Readers (2026-10-18)

The upper feature real-socket six-credit fixture now supports holds
UNBLOCK_H3_CREDIT_HOLD_SECONDS=0.5 or integer 2..180, preserving
the original six-Reader/0.5s default, 8 KiB producer budget,
32 KiB per-Reader windows, bounded aggregate connection credit and
all original digests/fairness/accounting/terminal assertions. Large
hold watchdogs reserve time to finish after release. CI adds a
12-Reader/10-second hold against released CPAN Net::QUIC 0.05.
Manual 60-second example and meaning/limitations in docs/PERFORMANCE.md.
Check CI before claiming the new 10s case passes.

## Sustained same-connection HTTP3 profiler checkpointing (2026-10-18)

Opt-in sample tracking was added to the upper feature branch's isolated
direct-vs-unified HTTP3 workload profiler, with no production HTTP3,
Net::QUIC or native ABI edits. UNBLOCK_H3_PROFILE_CHECKPOINT_EVERY=N
(64..4096, 0 disabled) samples per-trial client VmRSS/PSS/private at
deterministic completed-request counts, plus elapsed, interval throughput
and in-flight requests. UNBLOCK_H3_PROFILE_WATCHDOG_SECONDS=60..3600
permits longer manually run trials; both client and server are protected.
Runs use the same authenticated connection across each trial's measured
requests and preserve strict response-body/status/callback checks.
Each mode/round still uses fresh isolated client/server processes.
Sampling is intrusive and not a stable throughput comparison, memory
deltas do not count Perl/native allocations, and wire-byte counts do not
count payload copies. Do not infer a leak from one RSS progression.

The released-CPAN Net::QUIC 0.05 integration workflow now includes a
2048-request / 128-warmup / 2-round / 16-inflight / mixed 4K-16K body
smoke with checkpoint interval 256 and watchdog 180s. Verify new CI;
longer manual example is in docs/PERFORMANCE.md. No merges, releases,
or changes to main; generic Net::QUIC feature remains separate.

## QUIC MAX_DATA: corrected bounded Reader credit and full CI PASS (2026-10-18)

This supersedes the historical handoff hypothesis that the 12-producer
HTTP3 stress failure requires another Net::QUIC release before HTTP3 0.13.
The standalone Net::QUIC MAX_DATA-wakeup regression did expose a real,
independent generic transport notification omission, but that was NOT
the cause of the upper 12-Reader aggregate-window deadlock.

Root cause, proven by the temporary native send-credit diagnostic:
with twelve deliberately held 32768-byte Readers and QUIC connection_window
458752, the server had connection MAX_DATA remaining zero, 12 registered
capacity waiters, active Stream0 credit about 26092, no unsent or retained
QUIC send bytes, and the client consumed only 98184 bytes of Stream0.
ngtcp2 coalesces MAX_DATA advertisements until enough connection receive
credit has been reclaimed; with eleven siblings held and this aggregate
window, Stream0 could not acquire sufficient additional credit to trigger
an update. This is a receive-budget configuration problem. Never fix it
by sending unsolicited ACK wakeups or by silently overgranting credit.

Upper REAL CI using RELEASED CPAN Net::QUIC 0.05:
workflow 39161358835 at code head fccde28c8cc330d29101c386408525d8d00d6616
PASS all steps: distribution tests, 13 Linux::Event real TCP/QUIC tests,
the original six-producer 1 MiB regression at 256 KiB connection window,
12 independently held 1 MiB producers at 512 KiB (2s hold), 16 at
1 MiB (3s hold), additional 12/16 32-MiB isolation runs,
128-KiB/4-MiB native-budget variants and direct/unified benchmark smokes.
All original SHA-256, fairness, per-stream Reader isolation, native
retained accounting and once-only terminal assertions were retained.

The parallel feature-pinned integration workflow 39161358785 also PASS
with Net::QUIC clean feature commit
1606308eeeaf29f2601fa166046703a4b4ba9491. This extra workflow remains
distinct from the CPAN-baseline integration workflow and is not required for
the HTTP3 0.13 dependency. Net::QUIC feature branch standalone 15/15
Linux 5.20-5.44, macOS and Windows CI 39161007332 PASS. Temporary private
_debug_send_credit XSUB has been REMOVED and is not in that clean commit.

The extended fixture keeps six-producer original behavior unchanged;
for streams 7-12 it uses 512 KiB connection receive credit, for 13-16
1 MiB, and for six it retains 256 KiB. The original 448-KiB 12-Reader
stress configuration remains available as an explicit diagnostic override,
but its deliberate flow-control deadlock is not a valid release gate.
See docs/PERFORMANCE.md for precise reproduction and limits.

Do NOT merge, tag, release or modify main. HTTP1/HTTP2/HTTP3 production
code, released Net::QUIC 0.05, Uniform::HTTP and all main refs remain
unchanged in this scope. HTTP3 0.13 can use the published 0.05 prerequisite.
Performance work still open: controlled allocation/copy measurements,
repeatable high-concurrency throughput/latency and long-duration soak runs.
Documentation-only commits after fccde28 do not change verified code.

## Verified 16-producer isolation and 32-inflight HTTP3 profiler (2026-10-18)

Latest upper source before this handoff-only commit:
7054b96f7207ab8f3f0b6a064c740c2765dd7f23.
Full integration run 39158428479 is deliberately RED because the retained
12-producer tight-connection-window regression remains reproducibly stalled.
Do NOT call this overall integration passing or remove that fixture.

All of the following checks inside that run DID PASS:
- Original six-producer real UDP/QUIC 1 MiB regression.
- 12 simultaneous producers, 1 MiB each, 2s hold, 32 MiB connection
  receive window, 32 KiB independent stream windows, 8192-byte native
  advisory producer budget, SHA-256, complete fairness/retention assertions.
- 16 simultaneous producers, 1 MiB each, 3s hold, same receive/producer
  conditions with 32 MiB aggregate window; all payloads/terminal events pass.
- Isolated 32-inflight direct-vs-unified buffered response profiler smoke:
  64 requests, 16 warmup, two alternating rounds, 16 KiB response. Both
  modes completed, verified every body, reached 32 in-flight. Descriptive
  hosted CI median unified/direct wall ratio 1.052. DO NOT treat this
  two-round, short-workload ratio as a statistically established overhead.
  Client PSS/private/RSS are sampled only, not malloc or payload copy counts.

The tight 12-producer 458752-byte aggregate receive window still STALLS
after slow0 has received 98184 bytes, while its 11 siblings hold 32739
each. QUIC TX retention is 0; all 12 H3 writers are blocked and roughly
49.6 KiB of native streaming body remains retained. Widening only the
connection credit to 33554432 eliminates the stall. This supports an
unresolved standalone QUIC MAX_DATA / connection send-credit wakeup issue.
A generic possible fix would notify only actual Net::QUIC send-capacity
waiters when connection-level credit expands, through existing activity
API, without an HTTP-specific callback, poll loop or broadcast. This
hypothesis needs a standalone Net::QUIC regression before implementation.

Net::QUIC 0.05 is RELEASED and READ-ONLY: separate maintainer authorization
is required before any Net::QUIC code edit. HTTP3 0.13 and unified must
NOT merge or release while the tight-window stress defect is unresolved.
Current H1/H2 and all main branches are unchanged.
## 32-inflight direct vs unified HTTP3 profiler smoke (2026-10-18)

The existing isolated client/server `bench/h3-workload-profile.pl` accepts
up to 32 in-flight requests (was 16). Both paths still use the same
authenticated QUIC connection, identical HTTP3 server, payload and workload,
buffered body validation, separate client/server processes and per-trial
process isolation. A 32 x 16 KiB response wave stays under default 1 MiB
connection flow-control credit, avoiding the known aggregate-credit stall.
The live workflow now runs a 64-request / 16-warmup / 2-round 32-inflight
smoke before the known failing tight 12-producer case. This smoke is
correctness validation and descriptive CPU/RSS telemetry, NOT a benchmark
performance gate or malloc/copy-rate measurement. Verify CI results.
## Confirmed connection-window-sensitive HTTP3 starvation (2026-10-18)

The 12-producer experiment now distinguishes two cases with every Reader
stream_window=32768 and HTTP3 native send_buffer_limit=8192 unchanged.
Run 39157872356: 12 producers held for 2s PASS when only QUIC
connection_window is increased to 33554432 (32 MiB); all 12 finish with
SHA-256 integrity and producer/Reader fairness checks intact. With the
original connection_window=458752, the same run FAILED at 20s:
slow0 received exactly 98184 bytes, siblings each held 32739, QUIC TX
buffered bytes were 0 and all 12 H3 writers were blocked. This is a
connection-wide receive-credit/wakeup problem rather than a QUIC TX buffer
capacity issue. Keep the tight 12-stream failing case; do not weaken it.

Net::QUIC Stream->consume returns both stream and connection RX credit,
but on_stream_activity currently advertises stream-level send-credit and
ACK/capacity events. A peer MAX_DATA expansion with no per-stream activity
may leave HTTP3 output blocked; this is a hypothesis to validate at the
standalone QUIC layer before a transport fix. Net::QUIC is RELEASED and
READ-ONLY; no changes without explicit separate maintainer authorization.
Next CI adds 16 streams with a wide connection window to isolate HTTP3
per-stream scheduling at higher concurrency before the still-failing tight
aggregate-credit case. Do not merge/publish HTTP3 or unified with known
stress failure. No main branches modified.
## Aggregate QUIC receive-credit isolation probe (2026-10-18)

After 12-stream tight-window failure, probe CI 39157553715 recorded
QUIC transmit buffered bytes=0, native body retained=49591, blocked HTTP3
IDs 0,4,8,...44, ACK offsets 98261 for Reader0 and 32768 for siblings.
Producer0 accepted only 25 4-KiB chunks, all others 9. Reader0 received
98184 bytes and was stalled despite no outstanding QUIC send buffer.
Configured aggregate client receive window=458752, close to total bytes
received across all held streams. Connection-level send-credit exhaustion
is plausible, not yet proven. Next isolate by setting a wide 32-MiB
connection window while preserving individual 32768-byte Reader credit,
the 8192 native budget, staged release and all payload/fairness assertions.
Keep original tight-window 12-stream failure in CI as a separate case;
do not claim it resolved by allocating more connection credit.
## Extended HTTP3 stress exposed a new stall (2026-10-18)

Real UDP/QUIC CI 39157085119 FAILED at the new 12-producer, two-second hold.
The original six-producer test passed. All twelve Readers initially held
their independent ~32 KiB receive windows and all twelve producers started.
After release, slow0 received just 98184 bytes and stopped; only 25 complete
4 KiB writes were produced for slow0 and 9 for every other producer.
The watchdog fired at 60 seconds with no completion. This is a NEW
reproducible high-concurrency starvation finding, not a release-ready check.
Do not weaken or remove the 12/16 mode to obtain green CI.

This diagnostic commit adds a stress-only state probe while the QUIC
connection is still active (ACK offsets, native/QUIC retained bytes,
blocked H3 output IDs, producer and Reader progress) and shortens only the
stress-mode watchdog to 20 seconds. Its results are not yet verified.
Investigate root cause before any engine or Net::QUIC change. Keep both
libraries event-loop-neutral. No main branches changed.
## Scale-up of six-producer HTTP3 credit regression (2026-10-18)

The original six-producer test is retained as the default, with every
accepted-prefix, digested-body, per-stream reader-credit, native retained
accounting, producer-block/resume, fairness and terminal assertion intact.
The fixture now optionally exercises 12 producers held for two seconds and
16 producers held for three seconds on the same authenticated QUIC connection.
The connection receive window scales with the independent 32768-byte Reader
windows; the advisory native producer send budget remains only 8192 bytes.
The feature workflow runs default six and both larger modes. This is an
extended deterministic regression, not a true long-duration soak, allocation
measurement, hard memory cap or benchmark. Validate workflow results before
claiming those larger workloads pass. Neither HTTP3 nor Net::QUIC production
code changed in this step. All main branches remain untouched.

## Released Net::QUIC 0.05 / HTTP3 0.13 candidate integration verified (2026-10-18)

Net::QUIC v0.05 has been published to GitHub and CPAN. Net::QUIC main
beca1afdbc49e64a54827cd3118270e98469b0f7 is not modified further.
Unblock::HTTP3 feature/unified-receive-lifecycle now contains the 0.13
candidate, with all 15 modules versioned consistently, prerequisite
Net::QUIC >= 0.05, no development Net::QUIC installer/pin, updated docs,
PAUSE static-version regression, and released-CPAN-backed standalone CI.
H3 tested source commit 1bed34bc19213df6066fc72668cf0b9930de0d51
PASSED Linux 5.20/5.28/5.36/5.44 test matrix 39155065291 (including
5.44 distcheck/disttest/POD and installed native header test),
independent quic-go/public server interop 39154958488, Linux::Event
example smoke 39154958508 and benchmark smoke 39154810871. H3 subsequent
commit c743a1a6bf02189c49e7b865ca7e924d369ffadc is documentation-only.

Upper real-socket workflow removes its temporary Net::QUIC source checkout,
installs `Net::QUIC@0.05` from CPAN, verifies the version, and pins H3
0.13 candidate 1bed34bc plus unchanged H1/H2 feature source. Upper
workflow/Makefile commit 1e1645d6c4d7afbde50adb3ea0bd09deba2ec13c;
GitHub Actions run 39155180473 PASSED ALL stages: 552 distribution
assertions, 13 live TCP/QUIC files (including six independent 1 MiB HTTP3
streaming responses, one fast response and sequential Reader credit),
128-KiB and 4-MiB send budget variations and benchmark smoke.
SHA-256, exactly-once completion, fair producer resume and native retained
byte checks were retained. This validates the published Net::QUIC baseline,
not a development commit. Hosted benchmark timings are not performance gates.

No main, merge, release, tag or CPAN upload for H3/H1/H2/upper is authorized
by this verification. Net::QUIC remains independently useful and unchanged.
Pending sequence: maintainer approval to merge/publish HTTP3 0.13, then
coordinate HTTP1/HTTP2 remaining feature releases, and finally resume the
unified-layer release work. This section supersedes older handoff language
calling the now-released Net::QUIC 0.05 feature 'unreleased'.

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

## Six-producer HTTP3 starvation fixed: clean verified checkpoint (2026-10-18)

The six-producer real-socket regression is now FIXED and CI-VERIFIED.
Net::QUIC, kept independent of Unblock::HTTP and event loops, supports
optional Stream->send_some(..., limit_to_credit => 1) for bounded QUIC
flow-credit admission without changing default send_some semantics.
The decisive generic transport fix wakes only short-acceptance capacity
waiters via existing Stream activity when sibling ACKs free shared TX
buffer space. Initial H3 ACK broadcast experiment remains reverted.
No new HTTP3-specific scheduling loop or release-facing API change.

Hard evidence: six 1 MiB streaming responses plus a fast response sharing
one authenticated QUIC socket, 8192-byte send budget, six held 32768-byte
pull Readers released sequentially, then full digests, per-stream and
aggregate native byte accounting, exactly-once completion and write/drain
fairness. Verified upper feature CI 39147266161: 13 distribution files /
552 checks, 13 live real-socket TCP/QUIC files / 686 checks including six
producers, plus 64 and 58 additional QUIC budget checks and benchmark
smoke configurations: ALL PASS. Each of six streamed bodies produced all
256 accepted chunks. Cleaned source after removing temporary QUIC private
credit probes and fixture timers PASSED again in upper CI 39147574565
with the same stages and assertions.

Net::QUIC feature/fair-stream-send-capacity cleaned source commit
4d3a45aa2d3efb27523c6733c71d31cf527130a8 passed 15/15 Linux
Perl 5.20-5.44 and macOS/Windows CI 39147484627. H3 feature source
9d329e2adb64e0a71d58ee549f947b8972190d18 opts into the new
transport send mode only in its output bridge; H3 feature test matrix
39147558339 passed with NetQUIC's clean pin. Upper workflow now pins
NetQUIC 4d3a45.. and H3 9d329e.. . The six-stream fixture was retained,
not skipped or weakened; assertion wording updated for 7 total requests
in feature commit f31afc37191d133a75cc87d4f1bb885661edf065.

No main in any repo, merge, release, version bump or tag. Handoff.md
preserves the exact investigation history and CI run IDs. Net::QUIC is
viable as a standalone generic QUIC library. A release will require a
separately approved coordinated dependency version update: the released
NetQUIC 0.04 lacks this opt-in option, so do not ship H3 with an
unadjusted released NetQUIC prerequisite. Remaining priorities: longer
sustained slow-reader and larger concurrency repeatability, direct vs
unified allocation/copy measurements, and approved WebSocket upper
composition milestones. Hosted-runner timing is descriptive only.

## Coordinated standalone QUIC send-capacity wake feature (2026-10-18)

User authorized changes to Net::QUIC with the strict independent-library
requirement. The generic Net::QUIC feature/fair-stream-send-capacity adds
only OPTIONAL Stream->send_some(..., limit_to_credit => 1) and retains
original default send_some behavior. H3's two QUIC output bridges opt in
without introducing HTTP-specific logic into Net::QUIC. Net::QUIC CI
39146133370 PASS all 15 Linux/macOS/Windows jobs; H3 feature CI
39146362177 and 39146357011 + Linux smoke 39146362182 PASS.

Upper six-producer CI 39146210996 still FAILED after this first integration;
slow0/1 finished, but slow2-5 remained blocked while QUIC TX buffer=0.
A private diagnostic XSUB and upper probe conclusively measured remaining
connection credit 261956, per-slow-stream credit ~32589-32763, unsent
bytes 0, and QUIC buffered TX bytes 0 at the stall. Native H3 streams
8,12,16,20 were still marked blocked. This was NOT an exhausted QUIC
flow-control window; it was a missing shared-send-buffer wake event.

Net::QUIC now tracks send_some callers whose accepted prefix was short;
when ACK on a sibling frees shared connection send capacity, it wakes
only those pending callers through existing generic per-stream activity,
not all streams. No HTTP dependency or new public callback. Net::QUIC
source commits a3fa2a66546adba8dd853070f5d1121f58fd643b,
5ed667e33e99dff4727873b1d6ae03aad913c349,
fcb62f70a8536120d60d18823d600d3f73585176; focused no-queue
sibling capacity wake test 4b6dc21511ea32a275da99a36a1de2fe9bf4317a.
Upper integration workflow pins exact NetQUIC feature commit in upper
workflow commit eab69b3b0d56ac1a4e4c85d7f9da0daab0421224,
run 39147266161 now underway. Standalone Net::QUIC CI 39147248665
underway. DO NOT call the six-stream regression resolved until both pass.
Temporary Net::QUIC private credit instrumentation and extra upper probe
must be removed once the regression is verified, followed by final CI.
The previous six-stream and three-stream fixtures stay in CI unchanged.
No main, merge, version or release work.

## Six-producer native/QUIC pressure diagnosis and H3 rollback (2026-10-18)

Diagnostic upper CI 39142115478 failed BOTH the existing three-Reader
fixture and new six-Reader fixture when using experimental H3 code
40868d12a343fc217a4aea01199c83ee5e511fe5. The measured six-reader
stall at 8 sec showed native retained 23634 bytes and QUIC retained send
bytes 8192 (full); blocked nghttp3 IDs 0,8,12,16,20, six unfinished
native producers, and ACK offsets 36896,32768,32768,24599,1008,5.
The credited slow0 Reader got 36864 bytes but no further progress;
several sibling Readers held independent credit. This isolates a severe
connection-wide QUIC send-buffer/output scheduling starvation under six
held Readers. It is NOT an allocation or hard-memory-bound observation.

The production ACK-unblock experiment was reverted fully to prior H3
Connection.pm source, H3 rollback commit
b6f068fde2e279258f9247a7b8c26252245d8008. H3 full matrix CI
39142506332 and interoperability 39142506370 both PASSED again.
Upper workflow now pins this exact rollback in commit
8ea44673be206e2c80b8cc9e241743f5953c6e59.
The six-Reader regression xt/linux-event-quic-six-credit.t remains in the
live workflow and is EXPECTED TO FAIL until the genuine shared QUIC
output-starvation issue is corrected; do not silently exclude it to claim
passing CI. Previous three-Reader and no-cancel join tests passed on the
original engine and are not production regressions. This branch is still
an active feature branch, not release-ready.

Net::QUIC remains explicitly read-only. Its Endpoint transport options
do not expose a send_buffer_limit knob; they configure connection and
stream receive windows. A correct fix may need permission for a separate
Net::QUIC scheduling investigation or a demonstrated safe workaround
in H3. Do not alter Net::QUIC without new authorization. Preserve the
six-stream reproducer and all metrics for a dedicated continuation.

## Six simultaneous H3 producers: active diagnostic (2026-10-18)

A new upper xt/linux-event-quic-six-credit.t increases the existing real
QUIC multi-Reader fixture from three to six independent 1 MiB streamed
responses plus a fast response, using 8192 advisory native send bytes,
32768 QUIC credit per Reader, 262144 connection receive window and
sequential Reader credit release. It preserves the accepted-whole-write
contract, per-stream native accounting, SHA-256 and once-only callbacks.
Unlike previous three-stream and join/cancel fixtures, this reproduces
severe producer starvation: original pinned H3 run 39141085484 and
adjusted missing-Reader fixture 39141149693 both failed after 60s.
Only streams 0 and 1 completed; streams 2-5 stopped after their first
accepted 4096-byte write, despite legitimate Reader credit release.
Do not weaken this regression or claim the extended stress passes.

Investigated H3 Connection's blocked_output and producer sharing.
The engine initially wakes a stream blocked by partial QUIC send only on
that stream's own activity. An ACK-driven sibling wakeup experiment on
H3 feature code 40868d12a343fc217a4aea01199c83ee5e511fe5
passed full H3 matrix 39141613551 and interoperability 39141613659;
upper pins it at 920eec03ad992766eb2f28a90eca9c5024968173.
However upper 39141722608 still FAILED after 60s: several streams
produced some bytes but then stalled, even after the attempted wakeup.
Therefore this production experiment is NOT verified as a fix.

The six-stream fixture now has an eight-second diagnostic probe
(cf12fd418a6264df090ee5ec9cc891afe4d8a20a) capturing QUIC send
retention, native body retention per stream, ACK offsets, number of
active native producers, blocked_output IDs and actual Reader progress.
CI 39142115478 is pending. Inspect its SIX-CONTEST probe before further
production work. Do not remove the failing test merely to green CI.
The established earlier upper implementation and its last verified
benchmark/three-stream CI remain intact. All main refs, versions, tags,
release state and read-only dependencies remain unchanged.

## Optional HTTP3 client heap and wire instrumentation (2026-10-18)

Starting upper branch 3ee7ce3163eaa14fa0cd80fa0339c0d0b7c95b53,
engine feature refs HTTP1 bb8349ef, HTTP2 51fb1ad9 and HTTP3
721395e9, unchanged. Read current handoff, performance docs and
client/profiler source before continuing. No main or dependency edits.

bench/h3-workload-profile.pl now samples /proc/self/smaps_rollup Pss and
Private_Clean + Private_Dirty at warmup/measurement boundary and measured
end, in the isolated client process only. Values are NA when unsupported;
these are NOT allocation counts, native-only bytes, nor memory bounds.
UNBLOCK_H3_PROFILE_WIRE=1 optionally measures client QUIC datagram bytes
and packet counts at the host send/receive callback boundary during the
measured phase. Those counters do NOT measure payload copies or retention.
UNBLOCK_H3_HEAP_DIR optionally writes Devel::MAT::Dumper Perl heap snapshots
before and after measured traffic; optional module loaded only when requested,
not a runtime dependency. Snapshots show live Perl SVs at two times and
perturb memory/CPU, so dump-enabled timings are NOT comparative benchmarks.
Nothing changes production Client, HTTP engines, Net::QUIC or Uniform.

Changes: benchmark code 2b09b5496722184e3e219c5be3bcbb834a555465,
performance usage docs 95ee2eae8bd142a76fce1e0ed1daa8f715e6858e,
CI optional-wire smoke cb13b182619684f0c09458902fc1df32e3bedd99.
VERIFIED integration run 39140829724 PASS: 552 distribution checks,
553 live TCP/QUIC checks, 64 extra 128-KiB, 58 extra 4-MiB checks;
all existing and new benchmark smoke cases passed. Logged isolated
client PSS/private values and measured UDP sent/received byte/packet totals.
For 24 measured mixed 4/16 KiB requests, sampled client received about
257 KiB wire bytes in either mode, but this is NOT Perl/C copy count.
Optional Devel::MAT heap mode was not exercised in this CI, requires
manual separate installation. See docs/PERFORMANCE.md for interpretation.

NEXT: increase simultaneous QUIC pull Reader/producer contention beyond
three, preserving tight advisory native send budget and per-stream credit,
watch for starvation and accounting discrepancies. Longer-term allocation
rate/copy counting needs dedicated instrumentation; do not optimize on
hosted-runner timing alone.

## Isolated HTTP/3 client resource profiling (2026-10-18)

Starting feature head da8032840d3f81beff37d60f3eb60bb46339ee27,
matching the latest user handoff. HTTP1 bb8349ef, HTTP2 51fb1ad9,
HTTP3 721395e9 also matched; H1/H2/H3 handoffs reviewed.
No shell checkout/fetch (DNS unavailable), so publication uses GitHub
connector with explicit upper feature branch only. All engine sources,
Net::QUIC, Uniform::HTTP and all main branches are unchanged.

bench/h3-workload-profile.pl now runs the same authenticated QUIC workload
with separate server and measured client processes per trial, forked before
creating sockets/event loops/QUIC. The dedicated server announces its bound
loopback port over a pipe and remains live until the client finishes body,
status and terminal-callback verification for every warmup/measured request.
A client completion signal then ends the server loop; the server child
reports its exact request count or error. Each trial still alternates modes
and is independently forked from the coordinator. This isolates client
process CPU (CLOCK_PROCESS_CPUTIME_ID) and client sampled VmRSS from the
server process. The measured client still includes event loop, QUIC, TLS,
engine and kernel work; shared RSS mappings, allocator counts and payload
copies are not measured. End-to-end time still depends on server scheduling.
The workload and bounded concurrency have not changed.

Published code commit 4f5217f07a6c5416d6df639fa4ffa7b2f590bb1f and
performance documentation commit 61b8988eb17068ea129721e1807c5aa3cf4e27a6.
VERIFIED: run 39139264984 at handoff checkpoint 4c270b571c0b511c050f2f5b3211ea2339315479
passed 13 distribution files / 552 checks, 11 live files / 485 checks,
64 more at 128 KiB, 58 more at 4 MiB and the direct/unified benchmark
smoke configurations. The 16 KiB / 4 inflight and 256 KiB / 2 inflight
samples report client_cpu and client_rss fields separately. These are
hosted-runner observational samples, not evidence of a library-level
speedup, regression or hard memory limit.

A second late-join regression is now VERIFIED: new
xt/linux-event-quic-join-no-cancel.t begins two 1 MiB streaming H3
responses and a fast response on one authenticated connection. Under an
8192-byte native advisory send threshold, both initial producers must be
blocked before the third streamed request joins; neither is cancelled.
A tight send budget can delay the newcomer's response HEADERS, so the test
waits for its pull Reader rather than assuming immediate header arrival.
The fixture checks original client/server tx identity, three unfinished
native producers, end-to-end SHA-256 payload integrity, one-time terminal
callbacks, fair write(false)/on_drain/resume, bounded four-write bursts,
independent Reader credit and per-stream/aggregate native retained counters.
Initial fixture CI 39139536201 failed only the invalid immediate-third-Reader
assumption; it was corrected without weakening the blocked-producer requirement.
Final test commit 7932e6fcb4cef96927a2358bc928706bb995d468,
workflow commit 74d7b0d53be3151a74883306107c9bb566c5a0fb,
run 39139788344 PASSED: 13 dist files/552 checks, 12 live files/553
checks, plus 64 and 58 checks in additional native buffer-budget modes.
All profiler smoke tests passed. Observed native retained body peak 13618
at the 8192 advisory threshold; this is not an aggregate memory bound.

NEXT: extend measured performance workloads to larger H3 concurrency and
mixed response sizes while maintaining identical direct/unified fixtures.
Then investigate copy/allocation measurement options and sustained slow
readers; no speculative hot-path optimization from CI timings.

## Expanded HTTP/3 workload profiling (2026-10-18)

After separate-client/server isolation and no-cancel producer join were
verified, bench/h3-workload-profile.pl added deterministic mixed-size
response workloads. The fifth argument accepts one body size or up to eight
comma-separated byte lengths, each <= 1 MiB. When mixed, client requests
cycle URL targets /profile/0, /profile/1 etc. by request index; the
separate but identical server process chooses the corresponding body from
the target and both client modes validate it, including out-of-order
multiplexed completions. Single-size runs retain the old /profile route.
No protocol engine or QUIC source change; one connection per trial,
client-only process CPU and sampled RSS, alternating trial order, warmup,
and bounded concurrency remain unchanged. The script is a profiler,
NOT a CI performance gate.

Code commit c7ab7e174d047655d1cc8e82a885da468308f655,
PERFORMANCE.md commit 43b8e0fcb560b015dfe598e03d65157e8508df96,
and workflow smoke commit 829097cb80848404386569dadbe5f488bae6a040.
CI run 39140119509 PASSED this source: 13 dist files / 552 checks,
12 real TCP/QUIC files / 553 checks, 64 additional 128 KiB-budget
checks, 58 additional 4 MiB-budget checks, plus all five benchmark
smoke commands, including 16 KiB at 12 in-flight and alternating
4 KiB / 256 KiB at 8 in-flight. Both produced all valid response
bodies and once-only callbacks across three rounds per mode.

Descriptive hosted-runner medians: 16 KiB / 12 concurrent direct ~799.8
req/s vs unified ~740.2 req/s; mixed 4/256 KiB / 8 concurrent direct
~149.4 req/s vs unified ~139.0 req/s. Only 60 or 64 measured requests
per trial and three rounds; DO NOT assert precise performance regression
or optimization from these CI timings. Client-only CPU and RSS still
include Net::QUIC, TLS, engine, framework loop, shared mapped pages,
and all request buffering; process CPU excludes the separate server.
No allocation count, payload-copy count, or memory hard bound yet.

All four main branches were rechecked against the saved starting SHAs
and are unchanged. HTTP1/HTTP2/HTTP3 feature heads, Net::QUIC and
Uniform::HTTP were not modified in this continuation. No merge, tag,
release or version bump.

NEXT: isolate allocation/copy costs on comparable request/response paths;
exercise slow-reader pressure and larger numbers of simultaneous native
H3 producers; evaluate repeatability across controlled machines before
any change to the production Client hot path. Later return to the
approved WebSocket / H1 successor-consumer / H2-H3 composition milestones.

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

## Concurrent H3 CPU/RSS benchmark validation checkpoint (2026-10-18)

Initial benchmark source cbbca7182f9d6aa2721a01adf84cb765c0ea9098
and workflow 49f2968e5296d8bfdc7fed1b94cae38a8b041a98
PASSED upper CI 39136691305: 552 distribution, 485 live
TCP/QUIC, 64 at 128KiB, 58 at 4MiB, plus new benchmark smoke.
First two-round measurements with 30 requests / 16KiB / 4
outstanding, and 12 requests / 256KiB / 2 outstanding
showed small noisy serial-interval differences. However
whole-process RSS increased across alternating trials because
the trial objects lived sequentially in one Perl process.
Those memory readings were NOT comparable across modes.

The profiler now forks a FRESH CHILD PROCESS per trial, before
creating any loop, socket or QUIC connection; parent reads a
small JSON result over a pipe. No worker runs concurrently
with another trial. Process-wide RSS still includes both
Client and Server in the same child and is sampled rather than
a true peak. Isolation patch b63f08650c75c762b01b32ff75466465b5656bd6
PASSED upper CI 39136915734 with all prior distribution/live
checks and both isolated workload smoke settings. RSS startup
values were stable within modes rather than growing per round.

Additional docs in docs/PERFORMANCE.md commit
9877de612084ab7b84341b8004a084cae08142f8
explain sampling, fairness and rerun commands.
Follow-up profiler commit 82e5bf55f88e2e7515cd6b82e42be2b24f83b7a6
uses high-resolution Linux CLOCK_PROCESS_CPUTIME_ID rather than
quantized Perl times and a true average of even-round median
values. Workflow commit cff8be90c8f3b9183557addfea03ff516504ab43
increased the smoke to 100 measured / 20 warmup / 3 alternating
rounds at 4 in-flight, 16KiB, and 30/10/3 at 2 in-flight,
256KiB. Coordinated CI 39137178777 PASSED:
552 distribution checks, 11 real TCP/QUIC files / 485 checks,
64 extra checks at 128KiB and 58 at 4MiB, and all benchmark
smoke commands. Each isolated trial verified exact response
body, status, completed count and measured in-flight bound.

16KiB / 4 concurrent / 100 measured per round:
median direct 0.3526s (283.6 req/s), unified 0.3691s
(271.0 req/s), unified/direct elapsed ratio 1.047.
Direct mean synchronous request() call ~233-235us; unified
~301-314us. P50 response latency ~6.9ms direct and
~7.2ms unified. Observed isolated process RSS start
~27.2MiB direct versus ~27.9MiB unified; end
~33.7MiB direct versus ~34.8MiB unified.

256KiB / 2 concurrent / 30 measured per round:
median direct 0.9954s and unified 0.9955s (both
~30.1 req/s), elapsed ratio 1.000. Per-round CPU closely
followed elapsed on both, but includes server and client.
Isolated VmRSS peaks remained ~59MiB direct and ~60MiB
unified in these trials. These observed values are
NOT client-only memory, allocated bytes or a memory cap.

All results are shared-runner observations, NOT a stable
performance regression or confidence interval. They
establish repeatability/correctness of the new profiler
and initial workload shapes. Preserve raw logs at
https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/39137178777 .
Next: larger controlled bench on idle host, capture allocation
and copy counts, consider separate client/server process timing,
vary concurrent streams, body sizes, and slow receivers.

Benchmark compares a direct engine request with the full
URL-parsing pooled API by design, not an equal-cost wrapper.
Both use same Linux event loop, QUIC, server, payloads and
buffered receive. It is NOT a client-only CPU profile,
heap-allocation/copy count, or confidence interval.
Do not claim an improvement/regression from shared CI
runner trials alone. No production, HTTP1/HTTP2/HTTP3,
read-only dependency, main, version, merge, tag or release
changes in this continuation.

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
