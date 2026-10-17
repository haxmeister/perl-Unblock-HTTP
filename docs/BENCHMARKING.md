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

## Next benchmarks to implement

- Concurrent client sockets, changing connection/stream caps, idle
  retirement and origin fairness.
- Large buffered versus streamed body throughput, throughput under
  transport backpressure, timer scheduling and pause/resume correctness.
- Real QUIC/TLS H3 performance relative to direct HTTP3 Client attachment,
  with and without multiple concurrent streams.
- Report throughput, latency distributions, CPU, memory high-water,
  queued bytes, and copying rather than only a single requests/s number.
