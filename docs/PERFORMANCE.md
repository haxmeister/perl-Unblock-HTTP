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
```

The `h3-workload-profile.pl` arguments are **measured requests,
warmup requests, rounds, maximum requests in flight, and response-body
bytes**. The accepted ranges are documented in its usage error.

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
