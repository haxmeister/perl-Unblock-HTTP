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
independent 1 MiB streamed HTTP/3 responses plus an independent fast response
on one authenticated QUIC connection. It uses an 8192-byte advisory native
producer threshold, staged Reader release, per-stream receive credit, digest
checks, exactly-once completion and per-stream native retention accounting.
Do not weaken that default regression.

For an additional bounded contention check, the same test accepts
`UNBLOCK_H3_CREDIT_STREAMS` from 6 through 16 and
`UNBLOCK_H3_CREDIT_HOLD_SECONDS` of 0.5, 2 or 3 seconds. Each Reader keeps its
own 32768-byte advertised receive window. The connection window scales to
permit all independently held Readers, with headroom for the fast request.
The extended modes do not change protocol engines or application code:

```sh
UNBLOCK_H3_CREDIT_STREAMS=12 UNBLOCK_H3_CREDIT_HOLD_SECONDS=2 \\
    prove -v -b xt/linux-event-quic-six-credit.t
UNBLOCK_H3_CREDIT_STREAMS=16 UNBLOCK_H3_CREDIT_HOLD_SECONDS=3 \\
    prove -v -b xt/linux-event-quic-six-credit.t
```

The stress fixture also accepts `UNBLOCK_H3_CREDIT_WIDE_CONN_WINDOW=1`,
which sets connection receive credit to 32 MiB without changing any
individual Reader receive window, producer budget, assertion, or payload.
This is a diagnostic to distinguish connection-wide MAX_DATA wakeups from
ordinary per-stream receive flow control. The original bounded aggregate
window stays the default; the 12-stream tight-window case currently fails
and must not be skipped to claim a passing stress suite.

These are deterministic concurrency/forward-progress regressions, not
throughput benchmarks, lifetime memory caps, copy counts or long-duration
soak tests. Hosted CI can validate the constraints without supplying
meaningful peak-memory or production performance estimates.

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
