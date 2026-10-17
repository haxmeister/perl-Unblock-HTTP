# Implementation status and continuation plan

Updated: 2026-10-17
Branch: feature/high-level-client-server
Base: ad8ed8989a6c8fd9abd934f911a184116152be67
This is an incomplete development checkpoint, not a release candidate.

## Implemented in this checkpoint

- Server is a reusable definition with shared callbacks and protocol policy.
- attach_stream returns an actual HTTP1/HTTP2 Server engine.
- attach_quic returns a started actual HTTP3 Server engine.
- Only explicitly enabled protocols can be attached. TCP/TLS ALPN choices
  exclude H3 and disabled protocols. Unknown negotiation results fail.
- Configuration containers are copied at construction and attachment.
  Connection-local changes cannot modify the shared settings of other engines.
- The optional LinuxEvent adapter feeds the selected engine directly.
- QUIC server managers use one supplied Server definition. Ready callbacks
  receive the actual H3 engine. Startup reentrancy cannot attach twice.
- Transactions and callbacks retain their engine identity. No transaction
  subclassing, reblessing, method injection, or forwarding wrapper was added.
- The original whole-buffer output contract is unchanged.

Client is still the old single-connection interface. _Session remains only
for Client and uses the shared _EngineFactory. This is staging, not an attempt
to preserve the old API permanently. The former Server constructor and its
connection forwarding methods were removed without compatibility aliases.

## Deliberate incomplete behavior

Server callbacks still have their existing engine meanings:

- on_request: request headers have arrived;
- on_body: incoming body chunk;
- on_request_end: body and trailers have completed;
- on_error: engine failure.

The design requires a later application on_request callback, bounded buffering,
on_headers, and per-transaction on_data. Those are NOT implemented here.
The callback identity and timing tests protect only this foundation; revise
those tests when introducing the final application callback contract.

WebSocket enabling is rejected explicitly. H2/H3 Extended CONNECT advertising
is disabled, and conflicting engine settings are rejected. This does not yet
provide a complete H1 WebSocket permission gate: advanced code can still
invoke an engine's raw 101 response behavior. Full acceptance policy belongs
to the next transaction/transition stage. Do not claim WebSocket policy
conformance from the zero-valued option alone.

The optional adapter is still server-only. There is no transport factory,
URL request API, request-operation handle, pool, Alt-Svc cache, or automatic
WebSocket connection API yet. The full approved design remains the target.

## Engine work requiring separate repository authorization

The following findings came from H1/H2 0.11 and H3 0.12 source review.
Do not modify these distributions from this branch without approval.

1. Supported transaction construction extension.

   H1 Client/Server and H2 Client/Server instantiate their concrete Transaction
   classes directly; H3 Connection also constructs its Transaction directly.
   The real transactions lack the proposed on_data, pause/resume, and
   WebSocket convenience methods.

   Proposed minimal extension: an optional validated transaction_class, defaulting
   to the engine's own Transaction class. It must preserve the existing native
   construction path and permit a single-inheritance subclass owned by
   Unblock::HTTP. This lets the upper layer implement WebSocket conveniences
   without making individual engines depend on WebSocket or adding wrappers.
   Establish the constructor contract and benchmark it before choosing this
   approach over adding common receive/lifecycle methods to engine transactions.
   Do not implement by reblessing already-created transactions.

2. Receive-mode selection and completion before message freeze.

   H1 Server::_complete_request and H2 Server::_request_end freeze the Uniform
   request BEFORE invoking on_request_end. Their body callbacks deliver chunks;
   the upper layer cannot install one final buffered body at completion through
   the public Message API. Updating Message->body for every chunk would risk
   repeated copying; modifying private fields or thawing it is unacceptable.

   Preferred primitive: bounded engine receive-body buffering with per-transaction
   selection during the header callback, followed by one final body installation
   before freezing the message. H3 already has bounded receive modes; verify how
   to select them per transaction before the first body callback. A supported
   pre-freeze completion hook is an alternative if the upper layer owns the
   only body accumulator. Do not implement both accumulators.

3. Terminal notification and receive flow control.

   Add or expose a terminal observer that runs once for complete, cancelled,
   and error outcomes, including locally initiated cancellation. This is needed
   for on_finish, pool capacity release, and deterministic cleanup without polling.
   An intentional cancel must not be turned into an application error.

   H2 auto_consume/consume provides a starting point for receive credit. Check
   H3 Body::Reader/QUIC credit and H1 transport read control. Define pause/resume
   with bounded already-received data and preserve other multiplexed streams.
   Existing response on_complete alone does not establish the full terminal
   observer needed for both client and server.

4. HTTP/1 successor-consumer attachment.

   H1 already exposes on_switch and take_remainder. Its ordinary input path
   currently stops parsing at the switch and collects remainder bytes; its
   native path reports switched status. It does not transparently feed a new
   consumer through the same public/native input target.

   Proposed primitive: a generic successor consumer installed at the protocol
   boundary, after handshake output is accepted. Route bytes, EOF, errors,
   writable events, and native borrowed input consistently. Preserve same-read
   remainder exactly once. Keep WebSocket knowledge in Unblock::HTTP.
   Benchmark against a one-time adapter target update before fixing the ABI.

5. Safe H2/H3 stream composition and readiness.

   WebSocket's integration guide requires H2 output flushing after parser
   callbacks return. Verify or provide a supported post-dispatch mechanism so
   the upper layer does not depend on framework-specific polling or forbidden
   reentry. Retain bounded protocol-required queues only.

   Audit H3 stream capacity and connection lifecycle notifications before pool
   scheduling. The current QUIC manager scans all tracked connections per
   Driver event. Do not claim constant-cost lifecycle work. Net::QUIC's reviewed
   Connection API does not expose negotiated ALPN in its documented public
   interface; direct attach_quic callers must supply an H3 connection. The QUIC
   manager fixes its Driver ALPN to h3. A future generic factory needs verified
   negotiation metadata rather than assuming any ready QUIC connection is H3.

## Next implementation order

1. Agree the minimal dependency hook contracts and obtain authorization for
   their repositories. Preserve this branch while dependency work occurs.
2. Implement the final Server callback/body contract and transaction conveniences
   using those supported primitives; test nonempty and failed bodies first.
3. Implement internal H1 switching and H2/H3 WebSocket stream attachment with
   the same application policy on client and server.
4. Implement shared framework factories, bounded pending requests and Client
   scheduling. Specify pre-transaction error/cancel behavior for the recommended
   cancellable request-operation handle. Callbacks still receive real engine
   transactions once created; the handle must not become a body-method proxy.
5. Add reuse/capacity, strict version selection, validated in-memory Alt-Svc,
   conservative retry/fallback, and connect_websocket.
6. Complete live stress tests, direct-engine comparisons, and application versus
   adapter documentation before release consideration.

## Validation

2026-10-17: prove -lr t passes 5 files / 164 assertions. This includes independent
connections, protocol gating, configuration ownership, direct transaction and
callback identity, QUIC readiness/startup reentrancy, and invalid API arguments.

The isolated tests use doubles for native dependencies. They do not establish
wire correctness, native ABI compatibility, final callback semantics, or
performance. Real engine dependencies are not installed in this environment.
Live test sources were migrated but have not been executed here.

The integration workflow now targets feature/high-level-client-server. It
still installs engine repository heads; reproducible pins and additional live
coverage remain work for the next stages. No workflow has been triggered by
this local checkpoint. No benchmark result is claimed.
