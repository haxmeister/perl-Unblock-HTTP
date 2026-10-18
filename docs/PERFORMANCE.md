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
substitutes for those counters. CI runs a shorter 2048-request, two-round
instrumented smoke, not the 10,000-request manual example.

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
