# Request Policies

What happens between your call and the response: a deadline over everything, attempts inside it, and
a redirect chain inside each attempt.

## Overview

Three policies shape a request after you hand it over, and they nest. ``HTTPClient/timeout`` bounds
the whole logical request from the outside. Inside it, ``HTTPClient/retryPolicy`` decides how many
attempts the request gets and how long to wait between them. Inside one attempt,
``HTTPClient/redirectPolicy`` decides how far a `3xx` chain is followed, and the `401` refresh and
replay described in <doc:Authenticating> happens there too. A fourth setting,
``RequestOptions/coalescingKey``, sits beside the three: it decides whether a request is its own
exchange or shares one already in flight.

Each of the three is set on the client and overridden per request. A request's own
``RequestOptions/timeout``, ``RequestOptions/retryPolicy``, and ``RequestOptions/redirectPolicy``
take the client's place when they are set, and `nil`, the default on each, leaves the client's value
standing.

```swift
let client = HTTPClient(
  baseURL: URL(string: "https://api.example.com/v1")!,
  redirectPolicy: .sameOrigin,
  retryPolicy: RetryPolicy(
    backoff: BackoffSchedule(delays: [.milliseconds(100), .milliseconds(400)]),
    maxAttempts: 3
  ),
  timeout: .seconds(30),
  transport: URLSessionTransport()
)

let export = Request(
  options: RequestOptions(redirectPolicy: .never, timeout: .seconds(5)),
  path: "/export"
)
```

Every wait any of them asks for happens on ``HTTPClient/clock``, so a test advances it by hand
instead of waiting. See <doc:Testing>.

## Deadlines

``HTTPClient/timeout`` bounds a whole logical request, every attempt and the waits between them
included. `nil`, the default, means no deadline. When the deadline passes first, the request throws
``TransportError/transport(kind:underlying:)`` with ``TransportFailureKind/timedOut`` and no
underlying error, and whatever the exchange was still doing is cancelled. The failure is thrown once
that cancelled work has unwound, so a transport that ignores cancellation holds the caller past the
deadline for as long as it takes to notice. A deadline of zero or less has already passed, so the
request fails at once.

```swift
let search = Request(options: RequestOptions(timeout: .seconds(5)), path: "/search")
let results: [Match] = try await client.execute(search)
```

The deadline is the client's own, measured on ``HTTPClient/clock``. A transport's per-connection
deadline, such as a `URLSession` configuration's `timeoutIntervalForRequest`, is a separate and
lower bound on each send.

It sits outside the retry loop, so a timed-out request is never offered to ``RetryPolicy/retryable``;
a timeout the transport itself reports, one attempt taking too long by the transport's own measure,
still is. It also sits outside coalescing: each caller carries its own deadline, a caller whose
deadline passes leaves the shared exchange alone, and the exchange finishes for everyone still
waiting, exactly as a cancelled caller does. With a deadline set, the exchange runs in a child task
of the caller's, so it starts after the caller's first suspension rather than synchronously, and an
``HTTPClient/observer`` sees the interrupted send fail as the transport reported the cancellation
while the caller receives the timeout.

``HTTPClient/stream(_:)`` applies no deadline. A body that keeps arriving is the point of streaming.

## Retries

A request is attempted up to ``RetryPolicy/maxAttempts`` times. After a failed attempt with another
behind it, ``RetryPolicy/retryable`` is offered a ``FailedAttempt``: the failure, the attempt's
ordinal, and how long the request has been running. When it answers yes the client waits, and sends
again.

```swift
let policy = RetryPolicy(
  backoff: BackoffSchedule(delays: [.milliseconds(100), .milliseconds(400)]),
  maxAttempts: 3,
  retryable: { $0.failure.isTimeout || $0.failure.statusCode == 503 }
)
```

The default predicate retries timeouts alone. Retrying is safe when the server's application code
demonstrably never saw the request, which is what a timeout means and what no other failure does.
Widen it where you know your own endpoints are idempotent.

An attempt is the whole exchange: the credential read, the send, every redirect hop after it, and
the `401` refresh and replay when one happens. A replay follows the chain again from the resolved
request, so an attempt is two chains of up to twenty hops each, and ``FailedAttempt/elapsed`` counts
all of it together with the waits between attempts. A chain that reached the redirect limit ends in
the `3xx` it stopped at, so that is the status failure the predicate sees, and retrying it walks the
chain again.

The status is interpreted inside the attempt, so the predicate is offered a status failure as well
as a transport one and you can opt a `503` in. The body, by contrast, is encoded once, before the
first attempt, so an encoding failure is never retried. What the final attempt threw is what you
get, and a retried request reports no history.

Cancellation is checked between attempts, never around a send the transport is already running. A
request cancelled while it waits, or one that finds itself cancelled when an attempt fails, throws
``TransportError/cancelled`` and sends nothing further. A cancelled request is never retried,
whatever the predicate answers.

## Waiting as the Server Asked

When a retried failure carried a `Retry-After` field, the client waits what the server asked instead
of the schedule's ``BackoffSchedule/delay(forAttempt:)``.

```swift
// A 503 answering `Retry-After: 2` waits two seconds, whatever the schedule says.
let policy = RetryPolicy(
  backoff: BackoffSchedule(delays: [.milliseconds(100)]),
  maxAttempts: 3,
  retryable: { $0.failure.statusCode == 503 }
)
```

Four rules govern it. The field is read from the response the attempt ended on, a redirect the
policy stopped at included. Only the delta-seconds form counts: an HTTP-date is ignored, as is
anything that is not a whole number of seconds, and the schedule applies instead. The server's value
is waited as written, with no jitter, for whatever status the predicate chose to retry. And a wait
longer than what remains of the request's ``HTTPClient/timeout`` is cut short by the deadline, so the
request fails with ``TransportFailureKind/timedOut`` rather than completing the wait.

## Redirects

A `3xx` response that names a `Location` is followed under ``HTTPClient/redirectPolicy``. The
default, ``RedirectPolicy/follow``, follows to any origin; ``RedirectPolicy/sameOrigin`` follows only
while the scheme, host, and port stay those of the request; ``RedirectPolicy/never`` follows nothing.
A redirect the policy stops at is returned as the response it was, so every entry point throws it as
``TransportError/httpStatus(body:code:headers:)`` with the `Location` field in `headers`, and
``RetryPolicy/retryable`` is offered it like any other status failure.

```swift
let download = Request(options: RequestOptions(redirectPolicy: .never), path: "/export")
```

The `Location` is read as RFC 3986 reads a reference: absolute, or relative to the URL the `3xx`
came from, with dot segments resolved and any fragment dropped. One that names no authority at all,
`mailto:` or a bare `http:g`, is not a target and the `3xx` is returned.

The hop's request is the previous one sent again. A `301`, `302`, or `303` sends `GET` with no body
and without the `Content-Type` and `Content-Length` fields that described one, a `HEAD` staying
`HEAD`; a `307` or `308` keeps the method, the body, and every field. Twenty hops are followed, and
the twenty-first `3xx` is returned.

A hop to another origin, under ``RedirectPolicy/follow``, goes out without the field the client
attached from ``HTTPClient/authentication``, whichever field ``Authentication/scheme`` names, so a
credential meant for one host never reaches another; a field you set yourself in
``HTTPClient/defaultHeaders`` or on the request travels as you wrote it.

Each hop is a send: the ``HTTPClient/observer`` sees ``TransportObserver/willSend(_:)`` and
``TransportObserver/didReceive(_:)`` for every one, under the same attempt ordinal, and the duration
each carries is that hop's own. The `3xx` body is never read, and on ``HTTPClient/stream(_:)``
dropping it cancels whatever was still fetching it. A `401` at the end of a chain earns the same
refresh and replay as any other, and the replay sends the request as you wrote it, following the
chain again with the new credential. A ``RequestOptions/coalescingKey`` and a ``HTTPClient/timeout``
cover the whole chain.

## Coalescing

A request that sets ``RequestOptions/coalescingKey`` shares one exchange with every other request in
flight under the same key and the same credential, through this client or a copy of it. The first to
arrive sends, including the resolve, every attempt, and the `401` replay, and everyone who arrives
before that exchange completes receives its ``Response`` or its error.

```swift
let me = Request(options: RequestOptions(coalescingKey: "me"), path: "/me")

async let first: Profile = client.execute(me)
async let second: Profile = client.execute(me)
```

Each caller then interprets the shared response for itself: the typed
``HTTPClient/execute(_:)->R`` decodes its own copy on its own executor, and the four entry points
mix freely under one key.

A request whose key is `nil`, the default, never coalesces, and the client never derives a key. When
two requests that differ share a key, the first one's exchange is what everyone receives. The
credential is the one exception the client adds on its own: a request sent under one
``Authentication``, under another, or anonymously is three flights under one key, because a response
fetched with someone else's token is not the caller's answer. Use coalescing on idempotent reads
only; a write coalesced this way is sent once and answered many times.

Cancellation detaches the cancelled caller and nobody else. A caller cancelled while it waits throws
``TransportError/cancelled`` at once, first arrival or later, and the exchange runs to completion for
everyone still waiting. A flight every caller has left still finishes, so one send may be answered
for nobody, which is the price of never having to start a second exchange for a caller that arrives
late. A caller already cancelled when it arrives throws ``TransportError/cancelled`` without sending
or joining.
