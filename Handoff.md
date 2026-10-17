# Unblock::HTTP implementation handoff

Updated: 2026-10-17
Repository: haxmeister/perl-Unblock-HTTP
Branch: feature/high-level-client-server
Base main: ad8ed8989a6c8fd9abd934f911a184116152be67
Status: implementation checkpoint; H3/coordinated live validation pending.

## Resume here

Read this file, docs/design-handoff.txt, docs/IMPLEMENTATION.md and
docs/ENGINE-CONTRACTS.md. Inspect git status and branch before editing.
The user requested frequent handoff updates so work can continue in a new chat.

The user explicitly authorized changes to perl-Unblock-HTTP and its HTTP1,
HTTP2, HTTP3 dependencies. Keep ALL main branches untouched. Do not merge,
release, or change Net::QUIC/Uniform::HTTP. The dependency source checkouts
under deps are build inputs only, not authorized development targets.

Upper branch: feature/high-level-client-server.
All three engines: feature/unified-receive-lifecycle.
The user confirmed publication and coordinated CI on 2026-10-17. All three
dependency feature branches are published; further feature fixes are authorized.
Previous upper-layer feature publication was authorized. Do not push the new
upper code until its CI pins identify the new published engine commits.

## Current implementation

- Shared Server policy and direct real-engine attachment are implemented.
- Ordinary Server now maps on_headers to engine on_request, and application
  on_request to engine on_request_end. Callback references are mapped once.
- Buffered by default, 1 MiB per protocol; tune max_buffered_body_bytes in its
  protocol hash. receive_body is managed by the upper layer.
- tx->on_data at headers selects streaming. Same transaction/message identity;
  no extra body accumulator, wrappers, reblessing, or injected methods.
- tx->on_finish observes complete/error/cancelled once, after normal/error
  callbacks. Cancellation does not manufacture an error.
- Old upper on_body/on_request_end constructor options are removed, no aliases.
- Attachment checks on_data/on_finish capabilities and rejects released engines.
- H1/H2 add bounded receive buffers; H3 reuses its buffer/Reader. Engine default
  modes remain H1/H2 stream and H3 buffered, with a 64 MiB buffered limit.
- Empty already-frozen messages carry an empty string from construction.
  Public native ABI layouts/discovery paths are unchanged.
- H3 body-limit failure now resets its stream. Streamed request completion
  freezes the message before application notification.

## Validation checkpoint

Local Perl 5.38.2:

- HTTP1 full suite: 36 files / 320 top-level tests and subtests PASS.
- HTTP2 full suite: 30 files / 525 top-level tests and subtests PASS.
- Upper suite: 6 files / 182 top-level tests and subtests PASS; t/14 uses real
  H1/H2 engines, other files use doubles.
- H3 native, ownership and terminal callbacks: 3 files / 92 checks PASS using
  a local upstream nghttp3 build. Full H3/live QUIC suite NOT RUN: Net::QUIC
  is absent. Live t/24 is prepared; see the H3 handoff for exact build details.

H1 build: PERL5LIB=../deps/Uniform-HTTP/lib perl Makefile.PL; make.
H2 local build uses /tmp/http2-system-Makefile.PL, derived from the repository
configuration with real nghttp2 1.59.0 system library and matching headers.
Repository Makefile.PL is unchanged. CI must still validate the normal Alien
installation path. Scratch build inputs are reproducible, not published.

From each H1/H2 repo: PERL5LIB=../deps/Uniform-HTTP/lib make test
From upper repo, add these to PERL5LIB and run prove -lr t:
  ../deps/Uniform-HTTP/lib
  ../perl-Unblock-HTTP1/blib/lib
  ../perl-Unblock-HTTP1/blib/arch
  ../perl-Unblock-HTTP2/blib/lib
  ../perl-Unblock-HTTP2/blib/arch

The prior published foundation at 2003eb834e5ab7be2b88dfe78f32a42faa84a445 passed
https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/39051664280
(164 isolated, 10 live TCP/QUIC assertions). It does NOT validate current changes.
The latest published upper head before this work is 9860cf453f865252334ffda1ca9ef79ae958d897.

## Remaining work for this milestone

1. Local diff/POD review, focused edge-case tests and feature commits are
   complete. H3 full/live validation remains outstanding.
2. Publication is authorized and complete for all three engines. Run their CI,
   and fix failures. Record exact commits and workflow results in every handoff.
3. The integration workflow now pins the local engine commits listed below.
   Publish dependencies first and verify their remote SHAs. If publication
   creates new commit IDs, update these pins before publishing the upper branch.
   Run upper real-socket TCP and QUIC tests.
4. Mark ordinary Server milestone verified only after those results pass.
   No performance improvement or zero-copy claim has been established.

## Later milestones

Client redesign, factories, pooling, Alt-Svc, WebSocket transitions, complete
WebSocket policy enforcement, pause/resume and transaction-class hooks remain
pending. The optional LinuxEvent adapter remains server-only. Engine response
sugar already exists. See the full original design rather than improvising a
new API. No release/version bump is part of this checkpoint.

## Continuation prompt

Continue the four coordinated Unblock HTTP feature branches. Read the upper
Handoff.md and each engine Handoff.md first. Main must remain unchanged.
Ordinary Server receive/lifecycle code is implemented, H1/H2 local tests pass,
and H3/coordinated CI is the outstanding validation gate. Preserve actual engine
transactions, avoid duplicate buffering, and update handoffs after each milestone.

## Initial local engine commits (superseded by published commits)

- HTTP1: ea85251c3601fed3f2ec2bb0e7d86245112c4188
- HTTP2: 68dcb3ee32ffc952d6b0e9c3507ee1cd075c9a97
- HTTP3: 01e779e9c06674eaf983a511a752d7068b6f450f

These are local commits, not remote publication confirmations. The repository
working trees are clean after checkpointing. Git main refs remain at the
recorded baselines. Engine CI workflows run on feature-branch pushes.

Shell git can fetch but previously lacked credentials for GitHub push. The
connected GitHub create_tree/create_commit/create_branch/update_ref tools can
publish authorized feature work. Those tools may produce different commit IDs;
verify identical trees, update the upper workflow pins, fetch the published
branches, and synchronize local history without losing files. Never force-push
or update main. Record the actual published refs and CI results here.

## Authorized publication checkpoint

The user answered yes to publishing the engine feature branches and running
coordinated CI. Do not request confirmation again for this work.
Published engine commits (trees verified against the local checkpoints):

- HTTP1: 82dfc4bf691001aff50f96bb7a92e6fce3fbb229
  test run 39058702399; framework examples run 39058702329.
- HTTP2: 90639bf52394098296be4115e5485606ba6d7f92
  test run 39058704851; interop run 39058704842.
- HTTP3: d486f682530b436f4dc00f532f80cac669236db6
  test run 39058707266; interop run 39058707246.

These CI runs are in progress, not yet verified. Upper integration workflow
now pins these exact published commits. All main refs remain unchanged.
