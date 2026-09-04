# Concurrency Posture

Where a request runs, why nothing here is an actor, and what that buys you.

## Overview

Every target in this package builds with `.defaultIsolation(nil)`, `NonisolatedNonsendingByDefault`,
and `.strictMemorySafety()`. The first two together mean the public async surface is
`nonisolated(nonsending)` by the absence of an annotation, not the presence of one: a method runs on
the caller's actor until it truly suspends, and resumes back there.

What you feel is that there is no hop and no `Sendable` tax. A `@MainActor` model calling
``HTTPClient`` stays on the main actor through request construction, encoding, and the return from
the transport. Because the decoded value comes back as `sending`, the model it decodes into does not
have to be `Sendable` at all.

```swift
final class Profile: Decodable {
  let name: String
}

@MainActor
final class ProfileModel {
  private let client: HTTPClient
  private(set) var profile: Profile?

  init(client: HTTPClient) {
    self.client = client
  }

  func load() async throws(TransportError) {
    profile = try await client.execute(Request(path: "/me"))
  }
}
```

`Profile` is a non-`Sendable` `final class` and crosses the boundary anyway, because `sending` hands
over a value the decoder no longer holds. What the type does need is a `Sendable` metatype: the
bound on the decoding entry point is `Decodable & SendableMetatype`, because the type itself is
passed to the decoder. Every concrete type satisfies it unless its `Decodable` conformance is
isolated to a global actor, so you write the bound out only in generic code of your own.

## Nothing Here Is an Actor

``Transport``, ``TokenProvider``, ``TokenRefresher``, and ``TransportObserver`` are all `Sendable`
protocols, and none of their conformers should be an `actor`. An actor is a mandatory hop plus
async-everywhere infection: it puts a suspension in front of every credential read and forces
``TokenProvider/currentToken()``, which is synchronous so it can be read on every attempt without
cost, to become `async`.

Write a `struct` or a `final class` guarding its state with a `Mutex` from `Synchronization`
instead.

```swift
import HTTPCore
import Synchronization

final class TokenStore: TokenProvider, Sendable {
  private let token: Mutex<String?>

  init(token: String?) {
    self.token = Mutex(token)
  }

  func currentToken() -> String? {
    token.withLock { $0 }
  }

  func install(_ newToken: String) {
    token.withLock { $0 = newToken }
  }
}
```

`Mutex` is the vocabulary for anything needing a synchronous read, and `Atomic` is the vocabulary
for counters. `DispatchQueue`, `NSLock`, and `OSAllocatedUnfairLock` appear nowhere in the package.

``TransportObserver`` carries one extra requirement: its four calls are synchronous and run inline
on whatever actor is executing the request, or, for ``TransportObserver/didFinishBody(_:)``, the
read that ended the body, so keep its state behind a `Mutex`, format nothing expensive, and never
call back into the client that is reporting to it.

## The One Place a Hop Is Bought

There is exactly one `@concurrent` function in the package, and it is the JSON decode. Bodies at or
below 16 KiB are decoded inline on the caller's actor, and a larger one is decoded on the concurrent
executor. Both return `sending`, so which of the two ran is invisible from the outside, and a caller
that never receives a large body never pays for a hop. Nothing else hops on your behalf: not a
network call, not an observer report, not a credential read.

## Time Is Injected, Never Read

``HTTPClient`` takes a `Clock` and uses it for every wait it does. The retry loop sleeps on it, and
each send's duration in an observer event is measured with it. Nothing in the package calls
`Date()`, reads a wall clock, or sleeps on nanoseconds.

By default that clock is a `ContinuousClock`. In a test it is `RecordingClock` from the
`HTTPTesting` product, which records the durations it was asked to sleep and resumes sleepers only
when the test advances it, so a backoff schedule is assertable as a `[Duration]` value. See
<doc:Testing>.

## Cancellation

Cancellation is cooperative and checked where a check means something. ``HTTPClient`` checks it
between retry attempts, not before the first one and never during a send the transport is already
running, since a transport's own task already fails a cancelled request. A cancelled task's failure
is ``TransportError/cancelled``, a case of its own and not a ``TransportFailureKind``, because the
request did not fail: the caller left. It is never retried, whatever a policy's predicate answers.

The streaming primitives interpret cancellation instead of intercepting it. ``StreamedBody`` reads
`Task.isCancelled` between reads and installs no `withTaskCancellationHandler`, because a `mutating`
iterator under exclusive use cannot be reached from a `@Sendable` handler and every base that can
park a consumer already owns its own wake-up. The effect is that a clean end reported on a cancelled
task reaches you as ``TransportError/cancelled`` and not as end-of-data, which is what stops
`AsyncStream`'s cancel-as-`nil` from passing for a complete body.
