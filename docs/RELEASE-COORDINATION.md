# Coordinated Unblock HTTP family release plan (2026-10-21)

Status as of 2026-10-21: **all five changed repositories have been
fast-forward merged to MAIN and version-bumped release candidates are
on MAIN**. This document covers the remaining coordinated release
audits, tagging and publication; it is not evidence of any published
GitHub/CPAN releases. No version tags, GitHub releases or PAUSE uploads
were created during the merges. Current authoritative next steps
are also in each repository's main-branch Handoff.md.

## Current main-branch release candidates and order

The user specifically authorized merging these five release candidates
to their respective main branches, and has chosen to complete the
remaining release process in each distribution's own chat.

1. **Net::QUIC 0.06** - MAIN contains standalone MAX_DATA wakeup,
   six module version bumps and Changes; standalone 15-job CI
   https://github.com/haxmeister/perl-Net-QUIC/actions/runs/39693427664
   passed. Next release audit/tag/PAUSE upload occurs in Net::QUIC.
   Net::QUIC must remain fully standalone, not become an Unblock
   transport wrapper or acquire an HTTP dependency.
2. **Unblock::HTTP1 0.12** - MAIN includes streamed/buffered receive,
   terminal callbacks, attached-host output ordering and H1 Upgrade
   handoff. Standalone CI
   https://github.com/haxmeister/perl-Unblock-HTTP1/actions/runs/39694114939
   and framework examples 39694114991 passed.
3. **Unblock::HTTP2 0.12** - MAIN includes streaming/lifecycle,
   Extended CONNECT, stream-local flow control and restored installed
   NativeABI distribution smoke. Complete CI
   https://github.com/haxmeister/perl-Unblock-HTTP2/actions/runs/39699576879
   plus interoperability 39699576871 passed.
4. **Unblock::HTTP3 0.13** - MAIN includes the existing literal 0.13
   versions, H3 streaming/credit/SETTINGS, and native callback queue
   memory fixes. Standalone CI 39172771475 and independent quic-go
   interoperability 39172069428 passed. Its Makefile.PL currently
   allows Net::QUIC >=0.05, which was separately tested; do not
   raise this minimum to 0.06 without an actual need.
5. **Unblock::HTTP 0.02** - MAIN contains the unified Client/Server,
   H1/H2/H3 WebSockets and optional host reference examples. Its
   minimum engine dependencies are HTTP1 >=0.12, HTTP2 >=0.12,
   HTTP3 >=0.13, Uniform::HTTP >=0.06. Both FINAL coordinated
   full-workflow integrations, pinned to the final merged engines,
   PASSED on source 9db01d71bb0122134539b680adb2a6ebc7611e37:
   https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/39700432122
   https://github.com/haxmeister/perl-Unblock-HTTP/actions/runs/39700432046
   Verify installability against their ultimately RELEASED artifacts
   before publishing 0.02.

**Unblock::WebSocket** remains a separate, optionally loaded
distribution, with current main source version 0.02; it was not
modified or merged during this particular unified release preparation.
Verify that the required released WebSocket package/version is indexed
before advertising unified optional WebSocket support. Only bump it
if its own repository audit identifies unshipped changes and arrange
any needed release in its separate project chat.

**Uniform::HTTP 0.06** is identical to its existing published tag;
no modification or version bump is warranted in this train.

**Linux::Event** and **Linux::Event::HTTP** remain outside this
distribution release train. Do not install, bundle, maintain or
declare Linux::Event as a runtime dependency of Unblock::HTTP.
The maintained Linux::Event integration, if eventually built, belongs
in Linux::Event::HTTP by the user's explicit decision.

Next steps should be executed in each separate repository chat from
the authoritative main-branch Handoff.md. Prepare and publish in
dependency order; no tags, merges or PAUSE uploads have yet been done
as part of these versioned releases.

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
- Main branches already contain the authorized coordinated source.
  Future release tags, GitHub releases and PAUSE uploads must follow
  each distribution's own final audit and the user's permission.
