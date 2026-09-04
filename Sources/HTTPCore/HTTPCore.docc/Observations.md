# Bridging Observable State to Request Replay

Drive re-auth and stream reconnection from an `@Observable` model with the standard library's
`Observations` sequence.

## Overview

`Observations` (SE-0475) turns a closure that reads `@Observable` properties into an
`AsyncSequence`, re-emitting every time one of the properties the closure touched last time changes.
Nothing in `HTTPCore` imports `Observation` or ships a type for this: you compose ``HTTPClient``
with `Observations` directly, the way you would compose any other `AsyncSequence` with `for await`.
This article documents that composition. It is a pattern to write in your own code, not API this
package adds.

The usual shape is an `@Observable` model for whatever external condition should trigger a retry,
such as connectivity, an auth state flag, or a feature flag, observed from a loop that re-issues the
request each time the condition becomes true again.

```swift
import Observation

@MainActor
@Observable
final class ConnectivityState {
    var isReachable = true
}
```

```swift
@MainActor
func watchConnectivity(_ state: ConnectivityState, client: HTTPClient) async {
    for await isReachable in Observations({ state.isReachable }) {
        guard isReachable else { continue }
        _ = try? await client.executeExpectingNoContent(Request(path: "/ping"))
    }
}
```

The closure `Observations` takes is `@Sendable` and inherits the isolation of the context that built
the sequence. Pin the model and the watching function to the same actor, `@MainActor` above, instead
of making the model itself `Sendable`; a non-isolated `@Observable` class captured by the closure is
a compile error, not a runtime race.

## Composing with Authentication

``TokenProvider`` and ``TokenRefresher`` already own credential refresh:
``TokenProvider/currentToken()`` is read synchronously on every attempt, and a `401` triggers one
shared refresh no matter how many requests hit it at once. `Observations` decides when you re-issue
a request, never how a token gets refreshed.

Bridging an `@Observable` auth model looks the same as the connectivity example: observe the state
that changed, such as a sign-in flag flipping from `false` to `true` after an out-of-band
re-authentication, and re-issue whatever request was waiting on it. The refresh itself still goes
through the client's own single-flight path.

## Streaming and Reconnection

``HTTPClient/stream(_:)`` is not retried or reconnected by the client. The client throws once at the
top of the call and does no more after that. For a `text/event-stream`,
``HTTPClient/events(_:maxLineLength:reconnectDelay:)`` returns an ``EventSource`` that reconnects on
its own, carrying `Last-Event-ID` and waiting the server's ``ServerSentEvent/retry``; see
<doc:Streaming>. Each of its connections is a `stream(_:)` call of its own, reported to the observer
under its own correlation identifier, ``TransportObserver/didFinishBody(_:)`` included, and nothing
groups the connections of one ``EventSource`` beyond that. For any other stream, and for a reconnect
that should wait on a condition the server cannot signal, `Observations` over a connectivity model
is one way to drive it: watch for the condition that made the stream worth retrying, and call
`stream(_:)` again from the top when it arrives.

## Caveats

- The observation loop is a `Task` you own. Nothing cancels it for you, and nothing restarts it if
  the model it watches is deallocated. Cancel it by cancelling the task that runs it, as you would
  any other long-running `for await` loop.
- Neither `stream(_:)` nor the observation bridge retries on your behalf. The loop above is the
  whole mechanism, and it re-issues from the top every time, never resuming a partial stream.
  ``EventSource`` is the one sequence that reconnects on its own, and only for server-sent events.
- Do not single-flight refreshes yourself. The client already guarantees one refresh in flight per
  token, so a bridge that calls into a refresh path of its own on every observed change risks a
  second, redundant refresh racing the client's. React to the state changing, and let the client's
  own `401` handling do the refreshing.
