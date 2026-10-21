# Coordinated Unblock HTTP family release plan (2026-10-21)

Status: release PREPARATION on feature branches; not a published release.
No merges, tags, GitHub releases, PAUSE uploads or version edits to main
have been performed by this plan.

## Scope and dependency order

1. Net::QUIC: released 0.05; proposed next minor release **0.06**.
   Audit the latest `feature/connection-max-data-wakeup` branch,
   including independent standalone Net::QUIC usability, shutdown,
   MAX_DATA/request-credit wakeup, real QUIC/TLS tests, API and ABI.
   Avoid turning Net::QUIC into an Unblock-only dependency.
2. Unblock::WebSocket: current module reports 0.02. Inspect the
   code shipped to CPAN versus the handshake/streaming implementation
   required by unified H1/H2/H3, and bump to 0.03 **if a new WebSocket
   distribution is needed**. It remains a standalone module and an
   optional dependency of Unblock::HTTP.
3. Unblock::HTTP1: latest tagged version 0.11, candidate 0.12 from
   `feature/unified-receive-lifecycle`. Re-audit input switching,
   output ordering, native borrowed-input remainder, transaction
   callbacks, public NativeABI header and current examples.
4. Unblock::HTTP2: latest tagged version 0.11, candidate 0.12 from
   `feature/unified-receive-lifecycle`. Re-audit SETTINGS, extended
   CONNECT, stream body, on_drain and stream-local resets.
5. Unblock::HTTP3: latest tagged version 0.12, feature branch already
   reports 0.13. Candidate 0.13 (avoid redundant second bump).
   After Net::QUIC 0.06, verify the minimum Net::QUIC requirement
   matches the APIs H3 actually needs. Check current SETTINGS,
   credit wakeups and QUIC provider independence.
6. Unblock::HTTP: feature branch currently 0.01, candidate 0.02
   with the complete unified Client/Server/WebSocket APIs.
   Release ONLY after the lower distributions that are required
   by its install metadata are available in their correct versions.
   Finalize the exact dependency minimums only after those releases.

Uniform::HTTP 0.06 is an existing published dependency. Verify whether
any unshipped Uniform::HTTP changes actually exist before adding a
new Uniform::HTTP release. Linux::Event and Linux::Event::HTTP are NOT
part of this release train; no framework adapter will be bundled.

The GitHub compare audit of October 21 found the following
unshipped source changes against the last versioned GitHub tag:
- HTTP1 feature branch: 10 commits beyond v0.11.
- HTTP2 feature branch: 3 commits beyond v0.11.
- HTTP3 feature branch: 56 commits beyond v0.12.
- Net::QUIC development branch: 11 commits beyond v0.05.
- Uniform::HTTP main: IDENTICAL to v0.06, so do not bump it solely
  for this coordinated release.
- Unblock::WebSocket main currently reports 0.02 but no v0.02
  GitHub tag/release was found by this audit. Confirm PAUSE/CPAN
  state before deciding whether to publish 0.03.

All candidate version numbers except the already-set HTTP3 0.13 are
provisional until their distribution-specific audits and changelogs.
Avoid claiming an API is shipped from CPAN merely because the
coordinated feature branches pass CI.

## Unblock::HTTP source package boundary

Only framework-agnostic libraries under `lib/Unblock/HTTP` are
installable. No `Unblock::HTTP::Adapter::LinuxEvent` package is
installed or bundled. Reference Linux::Event adapter implementations
can live as inline code inside optional runnable example scripts.
The retained adapter code and unit tests reside solely under
`xt/lib/Unblock/HTTP/Adapter/LinuxEvent.pm` and
`xt/linux-event-adapter.t`, and `xt/` is excluded from MANIFEST.
The source distribution also excludes repository-only diagnostic
benchmarks; those remain runnable in the Git checkout and load
the xt/lib fixture explicitly when required. CI tests `make distdir`
to confirm the tarball contains no `xt/`, no `bench/`, no installed
adapter, and does contain the new `_WebSocketH2Body` code and all
current core tests. The distribution
declares no Linux::Event dependency.

A final tarball audit should inspect the generated MANIFEST, source
versions, release notes, PREREQ_PM, license, bundled examples,
complete POD, optional WebSocket behavior, test coverage and
installability using *released* engine versions, not only pinned
feature revisions. Verify a clean install and full `make test`
from the proposed release tarball.

## Release gates

- Every dependency is built/tested and published in dependency order.
- Each bumped version is applied consistently to package versions,
  version-indexed metadata and public headers where relevant.
- All current GitHub integration workflows and distribution tests
  pass after the final version/dependency updates.
- No missing test-only files or framework adapters in the tarballs.
- No accidental Linux::Event required/recommended dependency.
- Shared Client/Server examples and callback APIs remain functional
  with published dependency versions.
- Net::QUIC remains useful without Unblock::HTTP.
- Main branch updates, tags and external publishing occur only as
  explicit release actions after the audit, not during this
  feature-branch cleanup.
