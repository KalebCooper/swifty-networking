# Contributing to swifty-networking

Thanks for your interest. Contributions are welcome; the public surface is documented in the DocC
catalog, and every change to it lands in `CHANGELOG.md`.

## Getting started

1. Fork and clone the repository.
2. Open the package directory in Xcode 26 or later.
3. Build and run tests on the `swifty-networking-Package` scheme (⌘U), or `swift test` from the
   command line.

## Guidelines

- **Public API:** every public symbol needs a DocC comment.
- **Concurrency:** the public async surface is `nonisolated(nonsending)`; transports are `nonisolated`
  structs guarding shared state with `Mutex`/`Atomic`, never actors. Errors are typed at the transport
  boundary and mapped, not threaded, upward.
- **Tests:** Swift Testing only. Deterministic: inject a `Clock`, never sleep or read the wall clock.
  Target 100 ms per test. Every `@Suite` carries `.timeLimit(.minutes(suiteTimeLimitMinutes))`, the
  package-visible constant in `HTTPTesting`, so a test that stops making progress fails its suite
  instead of holding the run open. The limit cancels the test's task, so what it ends is a test
  suspended on something that never resumes, not one spinning synchronously. One minute is the
  shortest limit Swift Testing can express and is a guard, not the target; on a parameterized test
  it bounds each case rather than the whole argument set. A suite that opens a live socket is
  `.serialized` and waits only through a cancel-aware type; nothing under `Tests/` blocks a
  cooperative thread.
- **Style:** `swift format lint --strict --recursive Sources Tests` must report zero findings under
  the formatter in the `swift:6.3-noble` image, the one CI lints with. `Scripts/verify.sh` runs it in
  that container through Docker, so Docker must be running.
  Declarations are ordered alphabetically within their groupings unless initialization order or a
  logical dependency dictates otherwise.
- **Gate:** `Scripts/verify.sh` runs the format lint and every repository invariant the compiler
  cannot see (portable imports in `HTTPCore`, Darwin guards, the single `unsafe`, Swift Testing only,
  a time limit on every suite, and so on). Run it before every commit; it must exit 0.
  `Scripts/verify.sh --self-test` proves each check still trips on a planted violation.
- **Scope:** restraint is the feature. No interceptor chains, no plugin architecture, no macros.
  Open an issue to discuss additions before investing in a large PR.

## How it grows

These are the shapes a new capability takes, so that adding one never breaks the code already using
the package. A change that needs a different shape is worth an issue before it is worth a PR.

- A knob is a defaulted field on a struct (`TransportOptions`, `RequestOptions`, `Authentication`,
  `RetryPolicy`). Adding one never breaks source.
- An observer event is a protocol requirement with a do-nothing default. Adding one never breaks a
  conformer.
- An enum is used only for a closed set (`CachePolicy`, `RedirectPolicy`) or where the code that
  switches over it is the code that must adapt anyway (`TransportBody`: only transport authors
  switch).
- `HTTPClient` is non-generic. Injection never breaks.
- `Transport` has one required method, `stream`. New capability arrives as a body case or an options
  field, never as a second HTTP protocol.

WebSocket is a separate duplex capability with its own products and value types; it does not extend
HTTP `Transport` or `StreamedBody`. Its live backend protocols and adapters are not yet implemented.
Keep `WebSocketPortable` and `WebSocketHummingbird` independent and default off. Shared WebSocket
test scenarios belong in the internal `WebSocketTestSupport` target; network fixture dependencies
must remain trait-gated. Run `python3 Scripts/verify-consumer-graphs.py --output <new-directory>`
to verify fresh consumer resolutions without changing the working lockfile.

## Pull requests

- Target `main`. One concern per PR.
- Update `CHANGELOG.md` under **Unreleased**.
- CI must pass.

## Reporting issues

Use the issue templates and include a minimal reproduction where possible.
