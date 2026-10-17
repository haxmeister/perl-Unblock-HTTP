# Unblock::HTTP implementation handoff

Updated: 2026-10-17
Repository: haxmeister/perl-Unblock-HTTP
Branch: feature/high-level-client-server
Base: ad8ed8989a6c8fd9abd934f911a184116152be67
Status: implementation started; not release ready.

## Resume here

The maintainer approved the implementation plan on 2026-10-17 and asked
that this file be updated frequently so another chat can continue.
Read this file, docs/design-handoff.txt, and docs/IMPLEMENTATION.md first.
Check git status and the current branch before editing. Do not modify main.

Current checkpoint: reusable Server attachment and policy are implemented.
Client redesign and final Server callback/body semantics are NOT implemented.
Read docs/IMPLEMENTATION.md for the exact engine prerequisites and next steps.

Run: prove -lr t
Current result: 5 files / 164 assertions PASS (isolated engine doubles).
Native dependencies are absent, so live tests and benchmarks are unverified.

Next action: propose/approve the dependency extension contracts described in
IMPLEMENTATION.md and obtain authorization for the relevant repositories.
Do not claim the first complete Server milestone is done: default bounded
buffering, early on_headers, per-tx on_data and automatic WebSocket are pending.
The old engine callback timing remains explicitly documented at this checkpoint.

Files changed: Server, private _Policy/_EngineFactory, client _Session factory
use, QUIC manager, optional adapter, tests, README/POD, examples and CI branch
trigger. docs/design-handoff.txt preserves the original uploaded specification.
This file records the approved implementation plan and progress.

## Authorization and boundaries

Change only perl-Unblock-HTTP. Reading dependency sources is authorized.
Do not modify other repositories, merge, or release without approval.
The maintainer approved pushing this feature-branch checkpoint on 2026-10-17.
That approval includes the continuation records. It does not authorize main
changes or work in dependency repositories. Verify the remote branch on resume.
The uploaded design handoff supersedes the former roadmap, especially its
old exclusion of connection pooling. The package is Unblock::HTTP.
Unblock::Web is reserved for future UserAgent/web-application facilities.

## Approved implementation plan

1. Record contracts, callback order, cancellation, ownership and limits.
   Identify minimal engine prerequisites rather than injecting methods,
   reblessing objects, or adding transaction wrappers.
2. Turn Server into one reusable definition with attach_stream() and
   attach_quic(). Turn Client into a multi-destination manager. Use private
   policy/engine-construction helpers and return actual engines on attach.
   Absent http1/http2/http3 disables that protocol; {} enables it.
3. Implement Server first: bounded ordinary request buffering, on_headers
   before body delivery, on_request after successful body completion.
   Streaming selection uses per-transaction on_data registration. WebSocket
   handshakes dispatch early; H1 switches the whole connection, H2/H3 only
   the CONNECT stream. Preserve H1 remainder bytes and output ordering.
4. Define a shared optional framework factory for TCP/TLS, QUIC, listeners,
   and scheduling/cancellation. Support attachment, composition and subclass
   convenience APIs. Client owns bounded pending requests, connection reuse,
   capacity scheduling, and removal of failed/draining connections.
5. Add in-memory validated Alt-Svc discovery, strict http_version selection,
   conservative fallback, and client WebSocket connections. Never send the
   same request twice merely to race connections. DNS HTTPS is optional.
6. Test callback/lifecycle ordering, cancel/error/timeouts, backpressure,
   bounded memory, TLS ALPN, multiplexing, WebSocket, and QUIC timers with
   real engines/sockets. Benchmark integrated versus direct engines.
7. Update README, POD, examples and CI. Keep adapter-author documentation
   separate from application usage. Release work requires later approval.

## Architectural constraints

Pure-Perl orchestration, no required XS added here. Existing engines and
Net::QUIC retain their protocol responsibilities. Frameworks own sockets,
TLS, network queues, readiness and timers (seconds). Pool/discovery selection
stays off the per-byte path. Preserve native ABI/borrowed-buffer routes.
Use real engine transactions; no required forwarding connection object.
No method injection, multiple inheritance, compatibility aliases, or futures.
Code and POD use ASCII; POD belongs below code. Performance follows correctness.

Transport unblock_send accepts the WHOLE buffer or throws. True/undef means
ready for more; defined false means accepted but congested. Do not reinterpret
false as a partial write. Hard limits and oversized-write rejection still
need explicit contracts and tests. Avoid duplicate network buffering.

Deferred: multipart/file storage, redirects/cookies/routing/middleware,
0-RTT, preconnect(), optional dedicated WebSocket policies.

## Findings and prerequisites

Reviewed H1/H2 0.11 and H3 0.12 source interfaces. Transactions currently
lack public on_data(), pause()/resume(), is_websocket_request(), and
accept_websocket(). respond() accepts stream_body, not the proposed stream.
Concrete transaction classes are created directly by the engines. There is
no supported transaction-class factory in the inspected creation paths.
A clean implementation of those exact methods needs engine extension points;
do not silently use private-field mutation to fake their availability.

Existing engine on_request/on_response are header notifications. The upper
layer must delay its ordinary application notifications to body completion.
H1/H2 deliver chunks through on_body. H3 has bounded receive modes.
The exact body buffering and cancellation hooks need implementation checks.

H1 on_switch/take_remainder support a manual handoff. Direct input through
the same engine after upgrade needs a supported successor-consumer hook,
including the native path; do not add a permanent forwarding layer by default.
H2 WebSocket integration must respect parser reentrancy restrictions.
H2 has auto_consume/consume, but this is not yet the common pause/resume API.

QUIC manager currently scans all tracked connections after every packet,
timeout and writable event. Benchmark and examine lifecycle notification
support before claiming scalable constant-cost dispatch.

Cold Client request return value: approved plan recommends a small cancellable
request-operation handle for queued/connecting work, not a proxy transaction.
Callbacks receive actual transactions after creation. Precisely specify
pre-transaction failures and finish callbacks before implementing this.

## Checkpoints

- 2026-10-17: reviewed baseline; created feature branch; recorded full plan.
- 2026-10-17: implemented _Policy, _EngineFactory, reusable Server attachment,
  and shared-definition QUIC/LinuxEvent integration. The isolated suite passes
  5 files / 154 assertions. Examples and live test sources have been migrated;
  native live execution is still unavailable. Callback semantics intentionally
  remain engine-level; they are NOT the final buffered application contract.
- 2026-10-17: added startup reentrancy and closed-during-start QUIC regressions,
  circular policy validation, detailed dependency prerequisites, and migrated
  README/POD/examples. Isolated suite: 5 files / 164 assertions PASS.
  POD parsing, manifest presence and whitespace checks passed. The source scan
  found no non-ASCII text in code, tests, examples or continuation documents.
  Implementation checkpoint: 46c49058b2285cca8eabdeef3810946e2950632b.
- 2026-10-17: maintainer approved publishing this feature branch. Continuation
  records updated before the push. Check the remote head and CI on resume.

## Continuing in another chat

Use this prompt to continue from the published feature branch:

    Continue haxmeister/perl-Unblock-HTTP on feature/high-level-client-server.
    Read Handoff.md and docs/IMPLEMENTATION.md before editing. The original
    approved design is docs/design-handoff.txt. Main must remain untouched.
    The attachment/policy foundation is implemented and has 164 isolated
    passing assertions. Final buffered callbacks, streaming and WebSocket
    require supported engine hooks; other repositories still need explicit
    authorization. Do not mistake this checkpoint for completed Server or
    Client APIs. Update Handoff.md after every substantial milestone.

Fetch feature/high-level-client-server from GitHub and inspect its latest
commit before continuing. The publishing approval was for this checkpoint;
never push main or infer cross-repository permission. CI results are not yet
recorded here; verify the branch workflow before claiming live validation.
