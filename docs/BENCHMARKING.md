# Client performance measurement

This is development-only benchmarking for the Unblock::HTTP feature branch.
Run only after the distribution suite and live H1/H2/H3 tests are green.
Performance is an input to design decisions, not a substitute for protocol
and transport correctness.

## First reproducible comparison

    perl Makefile.PL
    make
    perl -Iblib/lib -Iblib/arch bench/client-vs-direct.pl 5000 500 5

The arguments are measured completed requests, warmup requests and rounds.
The harness runs the same short GET/200 loopback workload in two modes:

- direct: application uses Unblock::HTTP1::Client or
  Unblock::HTTP2::Client, with one attached Linux::Event TCP stream,
  constructs Uniform::HTTP::Request and registers callbacks.
- unified: application uses Unblock::HTTP::Client request sugar,
  with one framework connection factory, the same TCP stream type,
  and the matching native H1/H2 engine attached through the upper Client.

Both modes use the same Unblock::HTTP::Server definition and the same
Linux::Event framework. Every run starts a fresh listener/connection,
warms its engine, and issues one request at a time. It counts finished
requests and requires the server to have received each one. Protocols
are cleartext HTTP/1.1 and HTTP/2 prior-knowledge to avoid comparing TLS
handshake noise. Both have the same 1 MiB receive buffer limit.

The output includes elapsed wall time and requests per second, plus a
unified/direct wall-time ratio. This is a first low-concurrency comparison
of the Client application-facing path, not an end-to-end direct HTTP stack
comparison. It does not measure or assert zero copies, allocations,
cache pressure, CPU time, latency percentiles, slow receivers, stream
fairness, TLS overhead, or QUIC behavior.

## Measurement requirements

Do not treat a single CI run as a stable speed comparison. For a useful
local investigation:

1. Use the same pinned H1/H2 feature engine sources and Uniform::HTTP
   dependency in both modes; record the commits and Perl version.
2. Warm up both modes, repeat runs on a quiet machine, and inspect the
   distribution and variance of results. The current harness runs
   direct first, so additionally control run-order bias before treating
   small differences as real.
3. Repeat with keep-alive, H2 concurrency, varied header/body sizes,
   sustained streaming, and intentionally slow receivers in separate
   fixtures. Monitor maximum outstanding bytes and producer wakeups.
4. Instrument allocations/CPU profile and byte-copy counts at framework
   and engine boundaries before claiming fewer copies or faster dispatch.
5. Do not optimize by making the unified API perform per-body-chunk
   forwarding. Engine-owned framing, flow control and receive buffers
   remain mandatory.

The Actions workflow runs a short benchmark smoke check only to confirm
both modes can complete the same workload. No throughput threshold is used.

## Initial CI observations (not performance guarantees)

GitHub Actions real-sockets on the feature branch ran 1,000 measured
requests, 100 warmup requests and three alternating-order rounds per
protocol and mode, using a 1-connection, 1-in-flight GET/200 workload.
These are per-run medians from uncontrolled shared CI runners:

| Source | H1 direct | H1 unified | H1 ratio | H2 direct | H2 unified | H2 ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Before optimization, CI 39076051442 | 0.28021s | 0.37543s | 1.340 | 0.26195s | 0.35947s | 1.372 |
| Skip unnecessary quiet pool defer, CI 39076255077 | 0.27318s | 0.35407s | 1.296 | 0.25810s | 0.34514s | 1.337 |

A ratio greater than 1 means the unified Client took longer for the
same measured request count. The relative gap remains material in
this narrow test. The scheduling change removes an unnecessary
framework callback when no queued work, idle timer or retirement
needs it, and it passed the complete correctness suites. Differences
between CI runner machines and caching mean the two rows do not
establish a precise improvement percentage.

Do not extrapolate these numbers to bulk streaming, multiplexed H2,
QUIC/H3, slow receivers, CPU consumption or production capacity.

## Request-path profiling checkpoint (2026-10-17)

The loopback comparison now times the synchronous call to request() as
well as the full application-level request/response wall time. Both
the direct-engine and unified modes include Uniform Request creation
in that call; the unified mode also parses and validates the URL,
selects an origin and native engine, and performs pool admission.
The extra Time::HiRes calls perturb each measured request, so figures
should be compared ONLY to runs with identical instrumentation.

bench/request-setup.pl is an additional pure user-space microbenchmark.
It measures URI parsing/validation, Uniform::HTTP::Request construction,
and their combination separately, with no sockets, engine, or pool.
These measurements are descriptive, not a decomposition that sums to
precisely the total request() time.

First instrumented CI 39079013272, median us/request() across three
alternating-order rounds of 1,000 measured requests:

| Mode | H1 direct | H1 unified | H2 direct | H2 unified |
| --- | ---: | ---: | ---: | ---: |
| Original pool scheduling | 45.61 | 93.18 | 45.22 | 99.82 |
| Reusable connection direct-dispatch, CI 39079217496 | 45.10 | 87.77 | 45.42 | 95.26 |
| Same direct-dispatch + 9 regression checks, CI 39079251789 | 73.67 | 131.22 | 80.54 | 148.14 |

The first microbenchmark reported medians of 9.871 us for URI
validation, 10.425 us for Uniform construction, and 20.872 us for
the combined case. They are not additive to protocol execution.

The Client optimization bypasses full queue insertion and pool scanning
only if exactly one healthy ready connection can immediately admit
the request, with no existing queued work, maintenance, callback stack
reentrancy, or idle_timeout. Every other path stays with the general
bounded scheduler.

CI 39079251789 passed 552 distribution checks and 145 live H1/H2/H3
tests. The direct-dispatch path was also covered by targeted unit tests.
Runner-to-runner timing variation is substantial, so the exact apparent
speedup is NOT established. What is established: a redundant scheduler
scan was removed in a provably eligible case without breaking regression
tests. The remaining synchronous overhead is material and needs
subcomponent profiling before more risky parser or pooling shortcuts.

Run:

    perl -Iblib/lib -Iblib/arch bench/client-vs-direct.pl 5000 500 5
    perl -Iblib/lib -Iblib/arch bench/request-setup.pl 20000 5

## Slow-reader correctness evidence (2026-10-17)

The upper branch's xt/linux-event-slow-reader.t is a correctness
fixture, not a throughput benchmark. The actual LinuxEvent client
socket pauses reading for 120 milliseconds, then resumes. Its server
sends a reproducible six-MiB response through the unchanged H1/H2
engines using a 16 KiB high / 4 KiB low output-watermark configuration.
The test verifies per-byte SHA-256 integrity and response lifecycle
after read resumption. CI 39083903027 passed 552 distribution tests
and 168 live TCP/QUIC tests including this fixture.

On that CI runner H1 reported one real false result from the transport
write method and one later on_drain callback. H2 reported none:
connection and stream credit can limit H2 send output upstream of
the TCP transport. A successful slow-receiver transfer without a
transport-level false return is not evidence of no flow control.

The LinuxEvent high_watermark is advisory, not a hard cap on bytes.
LinuxEvent also has max_pending_bytes, but the upper layer does not
manage that queue or expose a pending-byte high-water measurement.
We have not established a bounded worst-case memory commitment,
per-chunk copy counts, or actual sustained receiver-rate throughput.

## Next benchmarks to implement

- Concurrent client sockets, changing connection/stream caps, idle
  retirement and origin fairness.
- Large buffered versus streamed body throughput, throughput under
  transport backpressure, timer scheduling and pause/resume correctness.
- Real QUIC/TLS H3 performance relative to direct HTTP3 Client attachment,
  with and without multiple concurrent streams.
- Report throughput, latency distributions, CPU, memory high-water,
  queued bytes, and copying rather than only a single requests/s number.
