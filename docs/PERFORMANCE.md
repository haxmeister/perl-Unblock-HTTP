# HTTP/3 performance experiments

The high-level Client and direct HTTP/3 engine need to be compared on the
same workload. These scripts are experiments, not performance gates. They
do not change protocol engines, QUIC, Uniform::HTTP or application APIs.

## Run them

Install the feature-branch dependencies described in
`Handoff.md`, and build this distribution with `perl Makefile.PL`
and `make`. With Linux::Event and the QUIC TLS stack installed:

```sh
perl -Iblib/lib -Iblib/arch bench/h3-client-vs-direct.pl 1000 100 7
perl -Iblib/lib -Iblib/arch bench/h3-workload-profile.pl 500 80 7 1 2
perl -Iblib/lib -Iblib/arch bench/h3-workload-profile.pl 500 80 7 4 16384
perl -Iblib/lib -Iblib/arch bench/h3-workload-profile.pl 200 40 7 4 262144
perl -Iblib/lib -Iblib/arch bench/h3-workload-profile.pl 500 80 7 12 16384
perl -Iblib/lib -Iblib/arch bench/h3-workload-profile.pl 500 80 7 32 16384
perl -Iblib/lib -Iblib/arch bench/h3-workload-profile.pl 500 80 7 8 4096,262144
```

The `h3-workload-profile.pl` arguments are **measured requests,
warmup requests, rounds, maximum requests in flight, and response-body
bytes**. The fifth argument also accepts up to eight comma-separated byte
sizes (for example `4096,262144`, each at most 1 MiB). Each size is
selected by the request's index in the current warmup or measured phase,
and encoded in its URL path so out-of-order multiplexed completion cannot
change the expected body. Both modes use the same deterministic request
sequence, server, payload contents and bounded concurrency. A single size
retains the original `/profile` path for backwards comparison.
The accepted ranges are documented in the script's usage and validation.

The profiler permits up to 32 in-flight requests, which can be used to
compare direct and unified response buffering at the upper pool's normal
per-connection multiplexing limit. At 32 x 16 KiB, one full in-flight wave
fits below the default 1 MiB connection receive window. This is NOT a
connection-credit starvation regression or a throughput guarantee.

The primary published Net::QUIC 0.05 integration CI now exercises **both**
16 and 32 concurrent requests, each with 128 warmup plus 2,048 measured
requests, two isolated rounds, alternating 4/16 KiB complete responses,
and per-256-completion memory and engine-registry checkpoints. This
compares bounded-retention behavior when the pool doubles its active
stream capacity, with no additional native copy/alloc counters. The
32-concurrency scenario is a resource and correctness stress, not a
repeatable throughput claim. Published Net::QUIC 0.05 CI
[39176260513](https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/39176260513)
PASSED, as did independent optional QUIC-feature CI 39176260525.
At 32 concurrent requests the unified private process memory in KiB
went 7,744 -> 7,900 (round 1) and 7,844 -> 7,860 (round 2);
direct memory went 6,744 -> 6,788 and 6,604 -> 6,716.
At every checkpoint unified ready_transactions stayed between 2 and
13 queue slots, not proportional to completed requests, and the
active engine transaction registry stayed within concurrency.
RSS/PSS also remained nearly flat. These are bounded-retention
observations for this particular callback-driven workload.

CI now also enables `UNBLOCK_H3_PROFILE_ASSERT_BOUNDED=1` for BOTH
the sustained 16- and 32-concurrent profiles. This opt-in diagnostic
requires registry checkpoints, and checks each 256-completion sample:
`ready_transactions <= concurrency+64`, live engine Transactions
`<= concurrency+1`, and no more than 8 MiB of private-memory growth
since measurement began. The last is intentionally a generous
regression guard for the original approximately 80+ MiB growth;
it is not a CI throughput performance gate or a universal memory
bound for arbitrary request/response sizes. RSS/PSS/private
memory do not count temporary Perl or native allocations or copies.

A trial uses two fresh child processes: one running the HTTP/3 server and
one running the measured client. They communicate over loopback UDP using
Net::QUIC::Driver. The same Unblock::HTTP::Server definition and response
body are used for both client modes. Direct mode uses Unblock::HTTP3::Client. Unified mode uses
the reusable Unblock::HTTP::Client, its URL parsing, pool scheduler,
and one attached HTTP/3 engine. Neither mode opens extra connections
to increase throughput. Up to the configured number of GET requests
can be outstanding at once.

Warmup must finish before the timed phase begins. Runs alternate
direct-first and unified-first order to reduce ordering bias. **Each
trial forks a client process, which forks a dedicated server process before
creating either event loop, socket or QUIC state.** The server announces
its UDP port through a pipe. After the client validates its last response,
it signals the server to stop; the server reports its request count and any
error before the next trial starts. This prevents one trial's native state
from accumulating in later trials. Both modes validate every buffered
response body and status. A request that does not finish, a wrong payload,
or an unexpected transport error aborts the experiment.

## CPU-only request-dispatch control

`bench/client-dispatch-profile.pl` compares a **ready, reusable**
`Unblock::HTTP::Client` and a direct fake HTTP3 engine with the same
`Uniform::HTTP::Request` implementation. It deliberately stubs only
`Unblock::HTTP3::Client`; the unified Client's URL validation, pool
lookup, operation lifetime tracking, callback adapters and scheduler
are real. Both paths finish a fake transaction and validate
`on_response` and exactly-once `on_finish` counts. Each round
alternates which mode runs first. No real HTTP3 frames, TLS, network,
Net::QUIC, response buffering or body copies take place.

```sh
perl -Iblib/lib -Iblib/arch bench/client-dispatch-profile.pl 20000 7
UNBLOCK_H3_DISPATCH_SPLIT=1 \
  perl -Iblib/lib -Iblib/arch bench/client-dispatch-profile.pl 20000 7
```

With `UNBLOCK_H3_DISPATCH_SPLIT=1`, a separate follow-up
run intercepts the **real** unified `_dispatch` method, the
fake H3 engine `request`, and the three constructors
`URI->new`, `Uniform::HTTP::Request->new`, and
`_ClientOperation->new`. It reports `request_us`,
`outside_dispatch_us`, `dispatch_us`, `fake_engine_us`,
`uri_us`, `uniform_us`, `operation_us` and a
`residual_us` that includes remaining validations, origin/pool
lookup, callback extraction and measurement overhead.
The phase timers wrap every request, and so change its measured CPU
cost. These phase totals are diagnostic and MUST NOT be directly
compared with the uninstrumented medians as if they were the same
measurement.

The full constructor-level diagnostic passed on published Net::QUIC
0.05 CI [39174909939](https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/39174909939).
All three rounds measured the same 3000 mocked requests/callbacks.
The reported averages in microseconds/request were:

| Measured call/boundary | Round 1 | Round 2 | Round 3 |
| --- | ---: | ---: | ---: |
| Instrumented unified request() | 74.392 | 74.790 | 74.245 |
| URI->new | 10.151 | 10.109 | 9.990 |
| Uniform::HTTP::Request->new | 21.453 | 21.600 | 21.418 |
| _ClientOperation->new | 2.217 | 2.246 | 2.200 |
| Outside dispatch residual | 30.511 | 30.631 | 30.485 |
| _dispatch (including fake request) | 10.059 | 10.204 | 10.153 |
| Fake engine request | 2.010 | 2.015 | 1.991 |

These boundaries show no single justified replacement for canonical URL
and Uniform construction, and the residual includes miscellaneous
validation, callback extraction, origin-key/pool operations and
timing overhead. Constructor timing and enclosing request timing
**overlap**; do not sum each line, assume exact cost attribution, or
infer network/QUIC speedup from this mock.
The complete upper published-0.05 workflow and the separate optional
transport-feature workflow
[39174909923](https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/39174909923)
were successful.



The pre-constructor-split primary published-Net::QUIC-0.05 integration
workflow [39174402639](https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/39174402639)
PASS reported three separate CLOCK-INSTRUMENTED rounds:
`request_us` 47.627, 47.523, 47.455;
`outside_dispatch_us` 41.133, 41.041, 41.020;
`dispatch_us` 6.494, 6.483, 6.435;
`fake_engine_us` 1.382, 1.386, 1.361.
The uninstrumented mock medians on the same run were direct 14.445 us
and unified 58.899 us per request/callback cycle. Different instrumentation,
different scope: those totals are **not** interchangeable. This result
motivated constructor-specific timing, not a production optimization
inside the very small fake engine boundary. They include clock and wrapper overhead; the phase
subtractions are approximate. In particular, `outside_dispatch`
includes URI parsing, Uniform construction, operation creation,
origin lookup, and the time spent outside the fast dispatch call.
It is not a direct count of object allocations.

This separates application request/dispatch overhead from real QUIC
transport costs. It is **not** a fair end-to-end direct-vs-unified HTTP3
benchmark, because the dummy engine removes shared engine/transport
work and the direct path does not parse a full URL or perform pooling.
The results are a diagnostic bound/lead, not evidence of a production
speedup or an actual native copy count. The separate
`bench/request-setup.pl` measures Uniform construction and URI
parsing in isolation. Compare this control with the real QUIC workload
before deciding where to optimize.

## Sustained independent-Reader stress

The real-socket `xt/linux-event-quic-six-credit.t` fixture defaults to six
independent 1 MiB streamed HTTP/3 responses plus one independent fast response
on an authenticated QUIC connection. Its 8192-byte native producer threshold,
sequential Reader release, digests, producer fairness, exactly-once completion
and per-stream retention accounting are unchanged.

The same fixture accepts `UNBLOCK_H3_CREDIT_STREAMS` from 6 through 16 and
`UNBLOCK_H3_CREDIT_HOLD_SECONDS` of 0.5 or whole seconds 2..180. Each Reader has its own
32768-byte receive window. The QUIC connection receive window also needs
space for blocked sibling streams and timely connection-wide MAX_DATA
advertisements. The tested bounded defaults are 256 KiB at six, 512 KiB
for seven through twelve, and 1 MiB for thirteen through sixteen streams.
These are configured receive-credit limits, not maximum process memory.

```sh
UNBLOCK_H3_CREDIT_STREAMS=12 UNBLOCK_H3_CREDIT_HOLD_SECONDS=2 \
    prove -v -b xt/linux-event-quic-six-credit.t
UNBLOCK_H3_CREDIT_STREAMS=16 UNBLOCK_H3_CREDIT_HOLD_SECONDS=3 \
    prove -v -b xt/linux-event-quic-six-credit.t
```

To test a prolonged period of withheld Reader credit on one connection,
set `UNBLOCK_H3_CREDIT_HOLD_SECONDS=10` (also supports whole seconds from
2 through 180). This leaves all 12 1 MiB producers attached on the same
connection while their Readers hold per-stream credit, then resumes them
in sequence and checks all payload hashes and callbacks:

```sh
UNBLOCK_H3_CREDIT_STREAMS=12 UNBLOCK_H3_CREDIT_HOLD_SECONDS=60 \
    prove -v -b xt/linux-event-quic-six-credit.t
```

This stresses a sustained **idle/flow-blocked** connection; it is not the
same as continuous 60-second throughput or 60 seconds of active reads. The
extended watchdog accounts for the hold plus bounded completion time.
The CI smoke runs a shorter 10-second held-Reader variant against
published Net::QUIC 0.05.

The previous diagnostic set a 448 KiB connection window for 12 deliberately
credit-held Readers. That fixture reliably stalled, despite each Stream
having its own 32 KiB window and registered QUIC send-capacity waiters.
The sender's connection send credit reached zero. ngtcp2 deliberately
coalesces MAX_DATA increases until sufficient receive credit has been
returned. With eleven other Readers held, the remaining aggregate receive
space was too small to let the one active Reader trigger that update.
Changing only the connection window to 512 KiB made all 12 complete with
the same native budget, payloads and assertions. A 16-Reader case passed
with a 1 MiB connection window. This is a receive-budget configuration
constraint, not evidence that HTTP3 should broadcast ACK wakeups.

For comparative diagnostics, `UNBLOCK_H3_CREDIT_WIDE_CONN_WINDOW=1` uses
a 32 MiB connection receive window. A selected diagnostic window can be
specified using `UNBLOCK_H3_CREDIT_CONN_WINDOW` (458752, 524288, 720896
or 1048576); the 458752-byte case is intentionally below the necessary
headroom for the 12-Reader workload and is not a passing correctness gate.

Published Net::QUIC 0.05 passed the original six-Reader and both expanded
bounded-window regressions in the upper integration CI. A separate
unreleased Net::QUIC feature branch independently corrects an activity
notification when peer MAX_DATA increases, but that fix is not required
for these correctly budgeted HTTP3 workload tests.

These are deterministic forward-progress regressions, not throughput
benchmarks, whole-process memory caps or measured allocation/copy counts.
Hosted CI timing remains descriptive rather than a release performance gate.

## Reading the numbers

- `req/s` and `wall`: measured completions and wall time in the
  post-warmup interval, including host event loop, UDP, TLS and HTTP/3.
- `request_us`: mean time spent inside the synchronous request()
  call; this includes URL/request construction in the unified Client
  and is **not** the full request/response latency.
- `p50_us`, `p95_us`, `p99_us`: time from application submission to
  its on_finish callback, including queuing and network scheduling.
  Percentiles are approximate nearest-rank observations, not
  confidence intervals. Tiny samples make p99 almost meaningless.
- `client_cpu`: measured client-process user plus system CPU seconds for the
  post-warmup interval, including client QUIC/TLS and the client event loop.
  It excludes server-process CPU, but not work charged to the client process
  in the operating system's networking stack.
- `client_rss_start_kib`, `client_rss_end_kib`,
  `client_rss_sample_peak_kib`: sampled client-process Linux
  /proc/self/status VmRSS at start, every 16 measured completions and
  at end. It excludes the separate server process, but shared mappings
  are counted in each process's RSS and it is **not** an allocator
  high-water mark or a reliable bound on transient peaks.

The client and server have separate process CPU clocks and address spaces.
Client CPU and RSS exclude the server process; the **client measurement
still includes the Linux::Event loop, Net::QUIC, TLS, UDP transport and
protocol engine**, and therefore cannot be attributed solely to the
unified library. RSS includes shared library mappings and copy-on-write
pages. End-to-end wall time still depends on the separate server, kernel
and scheduler. The script does not report server CPU/RSS, allocation counts,
Perl object counts, payload copies, nghttp3/QUIC per-stream retained-byte
surfaces, kernel buffers, packet loss, slow readers, streaming response
throughput or multi-origin pooling. The native retained-byte integration tests cover a distinct
part of those questions.

## Memory diagnostics and transport-byte accounting

The profiler now samples client-only Linux smaps_rollup memory **at the start
and end** of the post-warmup phase: \`client_pss_start_kib\`,
\`client_pss_end_kib\`, \`client_private_start_kib\` and
\`client_private_end_kib\`. PSS is proportional resident set size; private
memory is Private_Clean plus Private_Dirty. Values are printed as \`NA\` if
the kernel does not expose smaps_rollup. Neither metric counts allocations,
distinguishes Perl objects from native QUIC/TLS state, nor establishes a
transient maximum. Compare deltas only under otherwise identical conditions.

To count bytes and datagrams crossing the **client QUIC UDP socket boundary**
during the measured phase, enable the opt-in wire counters:

\`\`\`sh
UNBLOCK_H3_PROFILE_WIRE=1 perl -Iblib/lib -Iblib/arch \
    bench/h3-workload-profile.pl 500 80 7 8 4096,262144
\`\`\`

The reported sent/received byte totals include QUIC framing, ACKs, TLS
handshake follow-up traffic and retransmissions in the measured phase.
They do **not** count Perl string copies, borrowed-input copies or bytes
retained by nghttp3/Net::QUIC. This opt-in adds small per-datagram counter
operations; compare wire totals rather than treating its elapsed time as an
uninstrumented performance baseline.

For a snapshot of **live Perl SVs and their references**, the client can
optionally dump its heap at the warmup/measurement boundary and immediately
after the measured phase. Install \`Devel::MAT::Dumper\` separately; it is **not**
a distribution or benchmark-default dependency:

\`\`\`sh
cpanm Devel::MAT::Dumper
mkdir -p /tmp/unblock-h3-heap
UNBLOCK_H3_HEAP_DIR=/tmp/unblock-h3-heap \
    perl -Iblib/lib -Iblib/arch \
    bench/h3-workload-profile.pl 500 80 3 8 4096,262144
\`\`\`

For every direct/unified round, this produces two \`.pmat\` files named with
mode, round, client PID and \`before\`/\`after\`. Review them with
\`Devel::MAT\` analysis tools (separate optional installation). The dumps
describe **retained objects at two instants**, not the number of temporary
SVs allocated/freed in between. Native C heap allocations and kernel
buffers are not included. Heap dumping also perturbs heap state and can
consume substantial CPU/memory; ignore throughput, CPU and RSS
comparisons from heap-dump runs. Do not publish dumps indiscriminately:
they can contain application data, TLS state and strings from memory.

No instrument here can legitimately claim the number of internal
Perl-to-native payload copies. To determine copy counts, a separate
instrumented engine/allocator build or an allocation profiler with a
known scope and control workload would be required. Preserve the
production engine paths while gathering this evidence.

## Same-connection sustained profile and memory checkpoints

For a longer test of **one authenticated QUIC connection per client trial**,
the profiler accepts up to 20,000 measured requests. Warmup is excluded,
and each trial process (and its separate server process) stays alive for the
whole measured interval. A trial is fresh between direct and unified modes,
so inter-trial memory growth is **not** a valid leak indicator. Choose
in-flight concurrency and body sizes so the peer's connection receive
window retains sufficient aggregate headroom.

To sample memory at deterministic completed-request intervals, opt into
`UNBLOCK_H3_PROFILE_CHECKPOINT_EVERY` (0 by default; 64..4096 when enabled).
`UNBLOCK_H3_PROFILE_WATCHDOG_SECONDS` adjusts the independent client and
server watchdogs (60 by default; up to 3600 for a long-running trial):

```sh
UNBLOCK_H3_PROFILE_CHECKPOINT_EVERY=256 \
UNBLOCK_H3_PROFILE_WATCHDOG_SECONDS=600 \
    perl -Iblib/lib -Iblib/arch \
    bench/h3-workload-profile.pl 10000 256 5 16 4096,16384
```

Each `# checkpoint` record contains the client-process completed-request
count, seconds elapsed in the timed phase, interval throughput, number of
in-flight requests at the sampling instant and resident/PSS/private KiB.
Values come from the same child process and QUIC connection across the
measured requests. With the option disabled, there is no added smaps
sampling in the completion callback. Checkpoints **perturb throughput**;
run a separate uninstrumented trial for meaningful relative speed.
Compare repeated checkpoints with the same concurrency and workload,
not absolute RSS values between fresh forked processes. An upward memory
trend does not prove a leak, and flat resident memory does not establish
an absence of temporary Perl or native allocations.

This test continuously exercises buffering and multiplexing. It does not
hold arbitrary response Readers for minutes; that is a separate,
application-specific slow-consumer scenario. Native payload copy counts
remain unknown without source-level instrumentation at the exact copy
boundaries. UDP send/receive counts and retained-heap snapshots are not
substitutes for those counters. CI runs both a 2048-request, two-round instrumented retention smoke
and a 2048-request, three-round uninstrumented comparison; neither
replaces the 10,000-request manual dedicated-host example.

## Completed-Transaction retention fix and verification (October 18, 2026)

The upper Client's operation handle had an ownership cycle:
operation -> Transaction -> on_finish closure -> operation. The closure
also captured Client/pool/connection strongly. Callback-driven HTTP3
response completion therefore retained every finished Transaction while
the connection stayed open, even after the HTTP3 engine had begun using
weak entries for callback-owned pull notifications.

The upper feature branch now uses a strong active-operation registry
until terminal completion, with weak references from engine callbacks
back to the Client/pool/connection/operation. Handles intentionally kept
by the application still expose the **same real** engine Transaction.
The engine fix preserves callback/pull FIFO identity and strongly queued
pull-only entries. Its periodic weak-slot compaction (every 64 callback
insertions) also prevents a live old callback notification from pinning
thousands of expired weak *queue slots* behind it. Neither the active
transaction nor the payload is duplicated in a new wrapper.

Verification was performed against **published Net::QUIC 0.05**, with
the corrected HTTP3 feature commit
`5e0d496bb52331670edc9850d6fa417d984d0e67`, at upper CI
[39172126688](https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/39172126688).
The workflow completed distribution tests, real-socket TCP/H3 integration,
12/16 independent held-Reader stress including a 10-second hold, and
the deterministic 128-warmup + 2048-measured request profile in each
of two isolated direct and two isolated unified client processes.
All response bodies/statuses/callbacks were validated. The standalone
HTTP3 Perl 5.20/5.28/5.36/5.44 matrix
[39172069382](https://github.com/haxmeister/perl-Unblock-HTTP3/actions/runs/39172069382)
and independent interoperability
[39172069428](https://github.com/haxmeister/perl-Unblock-HTTP3/actions/runs/39172069428)
also passed.

| Client / round | Private KiB at start | Private KiB at end | PSS KiB start -> end | RSS KiB start -> end |
| --- | ---: | ---: | --- | --- |
| Direct / 1 | 6340 | 6416 | 11916 -> 11985 | 26524 -> 26576 |
| Unified / 1 | 7356 | 7480 | 12795 -> 12913 | 27152 -> 27260 |
| Unified / 2 | 7396 | 7436 | 12831 -> 12865 | 27180 -> 27204 |
| Direct / 2 | 6292 | 6364 | 11906 -> 11969 | 26580 -> 26624 |

At **every 256-completion checkpoint** (256..2048, both rounds),
unified HTTP3 `ready_transactions` had only **2 or 3 entries**;
the direct client had 1..5. Unified active HTTP3 transaction registry
was 1..16, streams 7..22, buffered QUIC send bytes 0..240 in this
workload; `ready_informational` was always zero. These figures are
snapshots taken during the completion callback, so one just-finished
transaction can legitimately remain visible. The earlier unbounded
unified `ready_transactions` count 2176 and ~95 MiB private end
footprint are no longer present. Private/PSS/RSS changes across the
2,048 measured requests are small in both modes.

These are **bounded-retention observations for this workload**, not
proof of no leaks for every user application or data size. RSS/PSS/private
do **not** count temporary allocations, native retained payload buffers,
or actual byte copies. User-held operation handles intentionally
retain the completed Transaction and its response by contract.
Unconsumed pull-only notifications remain strongly queued by design.

The memory-checkpoint run reported direct 1553.4 and 1574.1 requests/s
versus unified 1342.7 and 1365.1 requests/s on one hosted runner.
Its 256-completion smaps scans and registry introspection perturb
the timings; **do not use those figures as an API overhead benchmark**.
The matched 2048-request / 128-warmup, 3-round test **without**
optional checkpoint/registry/wire instrumentation passed against
published Net::QUIC 0.05 in upper CI
[39172590547](https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/39172590547).
Direct rounds delivered 1081.6, 1091.7, 1083.1 requests/s; unified
rounds delivered 998.5, 985.8, 994.3 requests/s. Median wall time was
1.8908 s direct versus 2.0598 s unified (ratio 1.089). Per-round
synchronous request() setup time was 136.30, 136.22, 135.92 microseconds
direct versus 190.52, 194.35, 189.95 microseconds unified.

End-to-end callback latency samples, in microseconds, were:

| Mode / round | p50 | p95 | p99 |
| --- | ---: | ---: | ---: |
| Direct 1 | 8848.9 | 14079.1 | 14632.0 |
| Unified 1 | 9366.0 | 12878.2 | 13964.9 |
| Unified 2 | 8923.1 | 12965.9 | 13721.9 |
| Direct 2 | 8769.0 | 13908.9 | 14315.8 |
| Direct 3 | 8759.0 | 13930.1 | 14559.0 |
| Unified 3 | 8789.1 | 12892.0 | 13344.0 |

All status/body and exactly-once callback validation passed. The
additional optional unreleased Net::QUIC feature diagnostic CI
[39172590469](https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/39172590469)
also passed, but is not a release dependency. The matched workload
suggests a measurable **request-construction/scheduling** difference at
this concurrency, not an identified individual hot-path cause.
The HTTP3 client remains correct and bounded in the independent
instrumented memory test.

**Do not interpret the 1.089 CI wall-time ratio as a stable overhead
estimate**. All results are single-run hosted Linux CI, with OS scheduling
and native TLS/UDP effects; they are neither dedicated-host repeated
benchmarking nor actual payload-copy/allocation instrumentation.
Request_us is time inside synchronous request(), *not* network latency.
The known audited byte copy sites in HTTP3 and Net::QUIC remain
unmeasured. A controlled dedicated-host profile at fixed versions,
multiple body sizes, equal concurrency, and repeated runs is needed
before deciding whether any native allocation/copy optimization is
worth production complexity.

The remaining measurement task is controlled repeated high-concurrency
latency and throughput on a quiet dedicated Linux machine with a fixed
Perl/XS/QUIC dependency set. Exact native copy/allocate counts would
require temporary counters at the audited copy sites rather than
extrapolating from RSS or UDP wire bytes.

## Comparing results fairly

Use a quiet, otherwise idle machine, a fixed Perl/XS/QUIC stack and
repeat several rounds. Compare the median and variation of both
modes for each **identical response size and concurrency**. Do not
compare different settings to claim an overhead or speedup. Report
full parameters, architecture, operating system, library versions
and the raw per-round results. Run again on multiple days or machines
before making quantitative performance claims.

GitHub Actions performs short correctness/smoke runs only. Hosted
runner CPU and memory scheduling vary; its timing numbers are useful
to spot obvious issues, not sufficient for a regression threshold.

Related: `bench/client-vs-direct.pl` covers HTTP/1.1 and HTTP/2 over
TCP; `xt/linux-event-quic-multi-credit.t` tests independent QUIC
receive credit, and `xt/linux-event-quic-join-cancel.t` checks
producer lifecycle under backpressure.
