# The Error Model

One typed error, five cases split by who failed, and a rule about what a description may say.

## Overview

Every throwing operation in this package throws ``TransportError`` and nothing else. Typed throws is
what makes that worth having: a `catch` clause binds the error as a `TransportError`, so a `switch`
over it is exhaustive without a `default`, and adding a case would be a compile error at every site
instead of a silent fall-through.

The cases split by who failed, which is what decides your next move: give up, fix the payload, read
the status, or retry.

```swift
do {
  let profile: Profile = try await client.execute(Request(path: "/me"))
  show(profile)
} catch {
  switch error {
  case .cancelled:
    break  // The caller left; there is nothing to report.
  case .decode(let underlying):
    report("The server's shape changed: \(underlying)")
  case .encode(let underlying):
    report("Nothing was sent: \(underlying)")
  case .httpStatus(_, let code, _):
    report("The server refused with \(code).")
  case .transport(let kind, _):
    report("No response arrived: \(kind).")
  }
}
```

``TransportError/encode(underlying:)`` is the one case that guarantees nothing left the process, and
it is never retried: the request is resolved once, before the retry loop, so a body that cannot be
encoded fails immediately.

Typed throws do not compose upward, and this package does not pretend otherwise. `TransportError` is
the boundary type. A domain client that wraps this one narrows to its own error and maps at that
layer, instead of threading one error type through the whole stack.

## Reading a Failure Without Unwrapping It

Three properties answer the questions a policy asks, so you rarely write the `switch` above at all.

- ``TransportError/isTimeout`` reports whether the deadline passed before a response arrived. It is
  what the default predicate on ``RetryPolicy`` reads from a ``FailedAttempt``, and the narrowest
  fact a replay can safely act on. A `408` or a `504` is the server's answer delivered as a
  response, so it is an ``TransportError/httpStatus(body:code:headers:)`` and not a timeout.
- ``TransportError/statusCode`` is the status for a refused response, and `nil` otherwise.
- ``TransportError/underlying`` is the coder's or transport's own error, where there is one.

``TransportError/description`` is safe to log: it names the case and the facts a log needs, and it
never prints a URL's query, a header field, or a body. The `HTTPURLSession` transport upholds the
same rule, which is why the error a `URLSession` failure carries is wrapped.

## The Failure Kinds

``TransportError/transport(kind:underlying:)`` carries a ``TransportFailureKind``:
``TransportFailureKind/badURL``, ``TransportFailureKind/connectivity``,
``TransportFailureKind/other``, ``TransportFailureKind/timedOut``. They are coarse, so a retry or
connectivity policy can tell a timeout from a dead network without downcasting a transport's own
error type, which would tie the policy to one transport and, on Apple platforms, to Foundation. A
transport maps whatever it cannot place onto `other` and keeps the original alongside it.

The `underlying` error is optional because not every transport failure has a system error behind it.
A `badURL` comes from the client's own base-URL join, and the client's own ``HTTPClient/timeout``,
like a mock transport, reports a `timedOut` with no system error to attach.

> Important: `error.underlying as? URLError` does not match. The `HTTPURLSession` transport
> wraps the original in a `URLSessionTransportFailure`, whose `code` property reads through to
> the `URLError` it holds and whose `urlError` property returns the original in full. The
> wrapper exists because
> `URLError` describes itself with the URL it failed on, routinely a signed one, and
> ``TransportError/description`` is safe to log. Match on `URLSessionTransportFailure` and read
> `code`, or read the ``TransportFailureKind``, which is what a policy should be reading anyway.

## Reading the Server's Own Error Shape

Servers answer failures with a body of their own design and no two agree on its shape, so this
package decodes nothing, names no field, and offers no protocol to conform to. The failure hands you
the bytes and the status; the type you read them as is yours to write.

```swift
struct APIError: Decodable {
  let code: String
  let message: String
}

func apiError(body: Data, status: HTTPResponse.Status) -> APIError? {
  // This API sends no envelope with a 404.
  guard status.code != 404 else { return nil }
  return try? JSONDecoder().decode(APIError.self, from: body)
}
```

Answer `nil` rather than throwing. A body that is absent, truncated, HTML from a proxy, or simply
not the envelope you expected all mean the same thing: there is no envelope to attach, and the
original status failure stands untouched. A throwing shape would let a malformed error body replace
a real `500` with a decoding complaint, which loses the only fact you definitely had.

Read it at the point you have the failure in hand and still hold the body, so the envelope travels
with your own classification step and ``TransportError`` stays free of your types. A failure from
``HTTPClient/stream(_:)`` carries the first 64 KiB of the body and no more, so read it the way you
read any other status failure's body and let a truncated one answer `nil`.

```swift
do {
  let profile: Profile = try await client.execute(Request(path: "/me"))
  show(profile)
} catch .httpStatus(let body, let code, _) {
  let envelope = apiError(body: body, status: HTTPResponse.Status(code: code))
  report(envelope?.message ?? "HTTP \(code)")
} catch {
  report(error.description)
}
```

``Response`` carries a zero-copy helper for deciding whether a body is worth giving to a decoder at
all. ``Response/contentTypeSniff()`` reads the body's own leading bytes, never the `Content-Type`
field, and answers ``ContentTypeSniff/empty``, ``ContentTypeSniff/gzip``, ``ContentTypeSniff/html``,
``ContentTypeSniff/jpeg``, ``ContentTypeSniff/json``, ``ContentTypeSniff/pdf``,
``ContentTypeSniff/png``, ``ContentTypeSniff/unknown``, or ``ContentTypeSniff/xml``, so a proxy's
HTML error page served as `application/json` is named for what it is. It reads the bytes in place
and allocates nothing.

When the body is worth decoding, ``Response/decode(_:with:)`` is the decode the typed
``HTTPClient/execute(_:)->R`` performs, available on a response you took whole. It reads the body
with the decoder you pass and applies the client's own size rule, so a large body is parsed off the
caller's executor rather than where the caller is running, and the value crosses back as `sending`
either way. A body that is not the type you asked for throws ``TransportError/decode(underlying:)``,
the same failure the typed entry point throws.

```swift
let response = try await client.execute(Request(path: "/me")) as Response
guard response.contentTypeSniff() == .json else { throw PayloadError.notJSON }
let profile = try await response.decode(Profile.self, with: JSONDecoder())
```

## What a Failure Does Not Reach

Two silences in the observer path are worth knowing, and both are about failures.

- A decode failure is not an observer event. It happens per caller, after the exchange is over and
  outside any attempt, and under coalescing many callers decode one shared response, so a failure
  event for one of them would misreport the single send that occurred. The decoding error reaches
  you as ``TransportError/decode(underlying:)`` and nowhere else.
- A coalescing joiner reports nothing. A request that joined a flight under the same
  ``RequestOptions/coalescingKey`` never reached the transport. The flight's own events are the
  record of the one exchange that happened.

A failure part-way through a streamed body is not silent, but it is reported differently: the read
that hits it reports ``TransportObserver/didFinishBody(_:)`` with the failure inline, before throwing
it to you. See <doc:Streaming>.
