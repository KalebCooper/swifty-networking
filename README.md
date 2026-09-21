# swifty-networking

[![CI](https://github.com/KalebCooper/swifty-networking/actions/workflows/ci.yml/badge.svg)](https://github.com/KalebCooper/swifty-networking/actions/workflows/ci.yml)
[![Docs](https://github.com/KalebCooper/swifty-networking/actions/workflows/docs.yml/badge.svg)](https://kalebcooper.github.io/swifty-networking/documentation/)
[![Swift Version Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKalebCooper%2Fswifty-networking%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/KalebCooper/swifty-networking)
[![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKalebCooper%2Fswifty-networking%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/KalebCooper/swifty-networking)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Swift networking package built on Swift concurrency. Build one client, describe a request, and get
back a decoded value, a raw response, or a stream of bytes, with a single typed error to handle and
test support included.

The unreleased WebSocket core provides an injected client, explicit connection ownership, a bounded
message inbox and send queue, synchronous submission, shared send completion and graceful close.
Limits, admission and failure policies, and operation deadlines are configurable. The URLSession
WebSocket adapter and the opt-in NIO client are implemented; the Hummingbird adapter is not yet implemented.

## In under a minute

Add the package, then build a client and make a typed request:

```swift
import HTTPCore
import HTTPURLSession

struct Profile: Decodable {
  let id: String
  let name: String
}

let client = HTTPClient(
  baseURL: URL(string: "https://api.example.com/v1")!,
  transport: URLSessionTransport()
)

let profile: Profile = try await client.execute(Request(path: "/me"))
```

That is the whole networking layer. Retries, credentials, streaming, and observers are added by passing
more to the same initializer, and none of them changes how a request is written.

- One `HTTPClient` value per API: base URL, default headers, JSON coding, redirects, retries, a
  deadline, credentials, and observers in one initializer. The type is not generic, so it is spelled
  `HTTPClient` wherever it is stored or injected, and `HTTPURLSession` adds
  `HTTPClient(baseURL:session:)`, which builds the transport for you.
- Redirects under a policy: `follow`, `sameOrigin`, or `never`, per client or per request, with
  `Authorization`, `Cookie`, `Proxy-Authorization`, and the credential field kept off any hop to
  another origin, whoever set them, and every hop reported to the observer. A transport never
  follows one on its own.
- Typed HTTP errors: every HTTP call throws `TransportError` and nothing else.
- Streaming as `AsyncSequence`: `stream(_:)` hands back a `StreamedBody`, a sequence of `Data`
  chunks, and the line splitting, NDJSON, and Server-Sent Events decoders each read one directly.
  `events(_:)` reconnects a Server-Sent Events stream on its own, carrying `Last-Event-ID` and
  waiting the server's `retry` on the client's clock.
- Pagination as `AsyncSequence`: `pages(_:as:next:)` returns a `PageSequence` that follows a `Link`
  header field, read with `WebLink`, or a cursor from the body, each page its own request through
  the whole client.
- A file body, `RequestBody.file`, that the transport reads from disk as it sends, a form body,
  `RequestBody.form`, encoded from the same `QueryItem` values a query is built from, a
  `multipart/form-data` body, `RequestBody.multipart`, built part by part from text fields and
  files, and a per-request cache policy that reaches `URLSessionTransport` as the matching
  `URLRequest.CachePolicy`.
- Test support as a product: a mock transport, a clock you advance by hand, a credential source that
  counts refreshes, and response fixtures.
- A portable core: `HTTPCore`, `HTTPTesting`, and `HTTPPortable` build and test on Linux and on
  Android. `AsyncHTTPClientTransport`, from `HTTPPortable` behind the trait of the same name, sends
  on both: a transport over AsyncHTTPClient that you build, use, and shut down.

## Installation

```swift
.package(url: "https://github.com/KalebCooper/swifty-networking.git", from: "1.1.0")
```

Add `HTTPCore` to any target that builds requests, `HTTPURLSession` to the one that sends them on Apple
platforms, `HTTPPortable` to the one that sends them on Linux and on Android, and `HTTPTesting` to your
test targets. `HTTPPortable` is behind a trait of the same name, so enable it on the dependency:

```swift
.package(url: "https://github.com/KalebCooper/swifty-networking.git", from: "1.1.0",
         traits: ["HTTPPortable"])
```

Versions follow semantic versioning, and every change is recorded in [CHANGELOG.md](CHANGELOG.md).

## Usage

### Sending a body

A `Request` carries an `Encodable` body, and the client encodes it with its own `JSONEncoder` at send
time.

```swift
struct SignUp: Encodable, Sendable {
  let email: String
}

let created: Profile = try await client.execute(
  Request(
    body: .json(SignUp(email: "person@example.com")),
    method: .post,
    path: "/profiles"
  )
)
```

A form goes out as `.form`, built from the same `QueryItem` values a query is, encoded as
`application/x-www-form-urlencoded` with a space as `+` and a literal `+` as `%2B`:

```swift
let session: Token = try await client.execute(
  Request(
    body: .form([
      QueryItem(name: "grant_type", value: "refresh_token"),
      QueryItem(name: "refresh_token", value: token),
    ]),
    method: .post,
    path: "/oauth/token"
  )
)
```

Text fields and files together go out as `.multipart`, built part by part and encoded in memory. The
form mints the boundary, so its `Content-Type` replaces one the request or the client defaults
carry:

```swift
var form = MultipartForm()
form.append(name: "caption", value: "On the trail")
form.append(contentType: "image/jpeg", data: photo, filename: "trail.jpg", name: "photo")

try await client.executeExpectingNoContent(
  Request(body: .multipart(form), method: .post, path: "/photos")
)
```

A file goes out as `.file`, and the transport reads it as it sends, so the bytes never pass through
memory:

```swift
try await client.executeExpectingNoContent(
  Request(body: .file(recordingURL, contentType: "video/mp4"), method: .put, path: "/recording")
)
```

### Handling a failure

Every HTTP call throws `TransportError`, so a `catch` binds the typed error and a status outside `2xx`
arrives with its body and header fields attached.

```swift
do {
  let profile: Profile = try await client.execute(Request(path: "/me"))
  show(profile)
} catch .httpStatus(let body, let code, _) {
  print("HTTP \(code), \(body.count) bytes of error envelope")
} catch {
  print(error.description)  // cancelled, decode, encode, or transport
}
```

### Decoding a response you took whole

`Response.decode(_:with:)` is the decode the typed `execute(_:)` performs, on a response you took
from `execute(_:) as Response`. It applies the client's own size rule, so a large body is parsed off
the caller's executor rather than where the caller is running, and the value crosses back as
`sending` either way.

```swift
let response = try await client.execute(Request(path: "/me")) as Response
guard response.contentTypeSniff() == .json else { throw PayloadError.notJSON }
let profile = try await response.decode(Profile.self, with: JSONDecoder())
```

`contentTypeSniff()` recognises JSON, HTML, XML, PDF, PNG, JPEG, and gzip signatures, and reads
anything else as unknown.

### Decoding with the response header fields

Annotate the call with a `DecodedResponse` and it carries the decoded body together with the header
fields and the status it arrived with. The body is decoded exactly as the typed `execute(_:)`
decodes it, so a large one still parses off the caller's executor. Reach for it when a header field
is part of the answer: an `ETag` to send back, a pagination cursor (see Paginating below), a
rate-limit budget.

```swift
let page: DecodedResponse<[Item]> = try await client.execute(Request(path: "/items"))
print(page.value.count, page.headers[.eTag] ?? "", page.status.code)
```

One method name, three results: `execute(_:)` returns a decoded value, a `DecodedResponse`, or the
raw `Response`, and the type you annotate decides which.

### Paginating

`HTTPClient.pages(_:as:next:)` returns a sequence of decoded pages, fetching each one after a rule
you supply names where the following page lives: a `Link` header field, or a cursor from the body.

```swift
let issues = client.pages(Request(path: "/repos/o/r/issues"), as: [Issue].self) { page, _ in
  WebLink.links(in: page.headers)
    .first { $0.relations.contains("next") }
    .map { .link($0.target) }
}

for try await page in issues {
  handle(page.value)
}
```

Nothing is sent until the sequence is read, `nil` from the rule ends it, and there is no page
limit. Each page is its own request through the whole pipeline: its own retries, deadline,
redirects, and credential rules.

### Authenticating with refresh

A `TokenProvider` supplies the current token and a `TokenRefresher` replaces it. An `Authentication`
pairs the two with the rules around them: the client attaches the token on every send and, on a
`401` ending a chain that reached the base URL's origin, refreshes once and replays the request
once, and a `refreshThreshold` makes it refresh before a send when the provider reports a lifetime
at or below it. Cancelling a request releases its refresh wait promptly and prevents its replay;
the shared refresh continues even if every waiting request has cancelled.

```swift
import Synchronization

final class TokenStore: TokenProvider, Sendable {
  private let token = Mutex<String?>(nil)

  func currentToken() -> String? { token.withLock { $0 } }
  func install(_ newToken: String) { token.withLock { $0 = newToken } }
}

struct SessionRefresher: TokenRefresher {
  let store: TokenStore

  func refresh() async throws(TransportError) {
    store.install(try await fetchNewToken())
  }
}
```

```swift
let store = TokenStore()

let client = HTTPClient(
  authentication: Authentication(provider: store, refresher: SessionRefresher(store: store)),
  baseURL: URL(string: "https://api.example.com/v1")!,
  transport: URLSessionTransport()
)
```

An `Authentication.Scheme` says how the credential is rendered. The default, `bearer`, sends
`Authorization: Bearer <token>`; `basic` sends `Authorization: Basic <token>`, the token being the
base64 RFC 7617 defines; and `field` sends the token unprefixed in the field it names. The rules
around the credential are the same under every scheme.
`Authentication.basicCredential(password:username:)` builds that base64 for a provider holding a
user name and a password rather than a token.

```swift
Authentication(provider: keyStore, scheme: .field(HTTPField.Name("X-API-Key")!))
```

### Retrying with backoff

A `RetryPolicy` names the delays, the attempt limit, and which failures earn another try. The
predicate is offered a `FailedAttempt`: the failure, the attempt's ordinal, and how long the request
has been running on the client's clock, so it can stop on a time budget as well as on a count. The
default retries timeouts only. A status that carries a `Retry-After` in seconds is waited as the
server asked, in place of the schedule's delay.

```swift
let client = HTTPClient(
  baseURL: URL(string: "https://api.example.com/v1")!,
  retryPolicy: RetryPolicy(
    backoff: BackoffSchedule(delays: [.milliseconds(200), .seconds(1), .seconds(3)]),
    maxAttempts: 4,
    retryable: { $0.failure.isTimeout || $0.failure.statusCode == 503 }
  ),
  transport: URLSessionTransport()
)
```

### Setting a deadline

`timeout` bounds a whole request, every attempt and the waits between them, on the client's clock,
and a request's own `RequestOptions.timeout` takes its place. Past it, the request throws
`TransportError.transport(kind: .timedOut, underlying: nil)`, whatever was still running is cancelled,
and the retry predicate is never asked. `nil`, the default, sets no deadline.

```swift
let client = HTTPClient(
  baseURL: URL(string: "https://api.example.com/v1")!,
  timeout: .seconds(30),
  transport: URLSessionTransport()
)

let search = Request(options: RequestOptions(timeout: .seconds(5)), path: "/search")
```

### Following redirects

A `3xx` naming a `Location` is followed under the client's `redirectPolicy`, `.follow` by default, or
the request's own `RequestOptions.redirectPolicy`. `.sameOrigin` follows only while the scheme, host,
and port stay the request's; `.never` follows nothing. A redirect the policy stops at is thrown as
`TransportError.httpStatus` with the `Location` field in its headers. A `301`, `302`, or `303` sends
`GET` with no body; a `307` or `308` keeps the method and the body. A hop to another origin goes out
without `Authorization`, `Cookie`, `Proxy-Authorization`, and the field `Authentication.scheme`
names, whoever set them; every other field travels as written. Twenty hops are followed, and every
one is a send the observer sees.

```swift
let client = HTTPClient(
  baseURL: URL(string: "https://api.example.com/v1")!,
  redirectPolicy: .sameOrigin,
  transport: URLSessionTransport()
)

let export = Request(options: RequestOptions(redirectPolicy: .never), path: "/export")
```

### Streaming a response

`stream(_:)` returns the body as a `StreamedBody`, an `AsyncSequence` of `Data` chunks that fails
only with `TransportError`, and each decoder reads one directly; a line, a field, or a value split
across two chunks decodes intact. Every transport streams: `Transport` requires one method,
`stream(_:body:options:)`, and `send(_:body:options:)` defaults to draining it. A status outside
`2xx` throws `TransportError.httpStatus` carrying the first 64 KiB of the body, so an error envelope
is readable from a stream without a second request. Server-Sent Events:

```swift
let body = try await client.stream(Request(path: "/events"))

for try await event in SSEDecoder(body) {
  print(event.event, event.data)
}
```

The same stream reconnected for you when it ends or drops, re-issued with `Last-Event-ID` after the
server's `retry` or three seconds, until the task reading it is cancelled:

```swift
for try await event in client.events(Request(path: "/events")) {
  print(event.event, event.data)
}
```

Newline-delimited JSON, one decoded value per line:

```swift
struct Record: Decodable, Sendable {
  let id: Int
}

let body = try await client.stream(Request(path: "/records"))

for try await record in NDJSONDecoder(body, decoding: Record.self) {
  print(record.id)
}
```

### Observing requests

A `TransportObserver` receives one event before each send, one after, and, for a streamed body, one
more when the body ends. Every requirement has a do-nothing default, so implement only the events
you want.

```swift
struct RequestLogger: TransportObserver {
  func didReceive(_ event: ResponseEvent) {
    print("\(event.method) \(event.url) -> \(event.status.code) in \(event.duration)")
  }

  func didFail(_ event: FailureEvent) {
    print("\(event.method) \(event.url) failed: \(event.failure)")
  }

  func didFinishBody(_ event: BodyEvent) {
    print("\(event.correlationID) body ended after \(event.bytesReceived) bytes")
  }
}
```

Pass it as `observer: RequestLogger()` when you build the client. The body event is reported from
your own read, the one that reached the end or the failure, so a body you drop before it ended
reports nothing.

With the `Logging` trait enabled, `LoggingObserver` is that observer already written against
[swift-log](https://github.com/apple/swift-log). Give it a `Logger` and each event is written at a
level per kind: `debug` for a send, `info` for a response, `error` for a failure, and `debug` for a
body's end.

```swift
let client = HTTPClient(
  baseURL: URL(string: "https://api.example.com/v1")!,
  observer: LoggingObserver(logger: Logger(label: "com.example.api")),
  transport: transport
)
```

The attempt, the credential flag, the correlation identifier, the method, the target, the send's own
duration in milliseconds, the status, and a body's byte count travel as metadata. No line carries a
header field, a body byte, or a credential the client attached; one the request itself carries in its
target, in the query string or the userinfo, appears there as it would in any other record of the
request.

### Deriving a client

A client is a value, so a variant of one is a copy with a property changed. Every public stored
property can be changed that way, `transport` included.

```swift
var beta = client
beta.baseURL = URL(string: "https://beta.example.com/v1")!
beta.defaultHeaders[.accept] = "application/json"
```

Assigning `baseURL` parses the new base at once. Copies share one coalescer, so copies that differ
in base or default header fields still coalesce under one `coalescingKey` and the joiner receives
the leader's response. Give copies whose responses must not be shared different keys.

A credential splits that on its own: a flight is keyed by the `Authentication` as well as by the
string, so a copy assigned another one never joins an exchange sent under the original's credential,
and it refreshes on that value's own gate. Assigning `transport` gives the copy a coalescer of its
own, so a response fetched through one transport is never handed to a request bound for another.

### Testing

`HTTPTesting` ships a `MockTransport` that answers from a queue and a `RecordingClock` that only moves
when you advance it, so a retry test asserts its delay instead of waiting for it. `MockTransport`
streams as well as buffers, from one queue: seed a `MockTransport.Answer` with the chunks a body
arrives in and, where the test needs it, the failure that ends them, and a client built over the
transport streams those chunks back, each as one element, or drains them into one response when it
sends. Seed a `Response` where the body whole is all the test cares about.
`RecordingTokenProvider` is the credential source: build an `Authentication` over the same instance
as provider and refresher, seed the token it holds and the outcome each refresh answers with, and
assert how many refreshes the client asked for.

```swift
import HTTPCore
import HTTPTesting
import Testing

@Test func retriesAfterATimeout() async throws {
  let clock = RecordingClock()
  let transport = MockTransport(results: [
    .failure(.transport(kind: .timedOut, underlying: nil)),
    .success(.ok(json: Fixtures.jsonObject(["id": "42", "name": "Ada"]))),
  ])
  let client = HTTPClient(
    baseURL: URL(string: "https://api.example.com/v1")!,
    clock: clock,
    retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [.seconds(1)]), maxAttempts: 2),
    transport: transport
  )

  async let profile: Profile = client.execute(Request(path: "/me"))
  await clock.waitForPendingSleep()
  clock.advanceAll()

  #expect(try await profile.name == "Ada")
  #expect(clock.sleeps == [.seconds(1)])
  #expect(transport.requests.count == 2)
}
```

## Requirements

- Swift 6.2 tools, Swift 6 language mode
- iOS 26 / macOS 26 / tvOS 26 / visionOS 26 / watchOS 26
- [swift-http-types](https://github.com/apple/swift-http-types) 1.6.0+
- `HTTPCore`, `HTTPTesting`, and `HTTPPortable` build and test on Linux and on Android.
  `HTTPURLSession` is Darwin-only and compiles to an empty target elsewhere.
- An off-by-default `HTTPPortable` trait adds
  [async-http-client](https://github.com/swift-server/async-http-client) 1.36.1 and
  [swift-nio](https://github.com/apple/swift-nio) 2.102.0 and builds the `HTTPPortable` product over
  them; without the trait the product compiles to an empty target and a default consumer fetches
  neither package.
- An off-by-default `Logging` trait adds [swift-log](https://github.com/apple/swift-log) 1.15.0 to
  `HTTPCore` and builds `LoggingObserver` over it; without the trait the type is absent and a default
  consumer never fetches the package.

- An independent, off-by-default `WebSocketPortable` trait adds NIO 2.102.0+ and
  NIOSSL 2.37.4+ without AsyncHTTPClient.
- An independent, off-by-default `WebSocketHummingbird` trait adds Hummingbird 2.26.0+ and
  HummingbirdWebSocket 2.7.0+ for macOS/Linux adapter scaffolding. It does not require
  `WebSocketPortable`. Default and client-only consumers do not resolve Hummingbird.
- The URLSession adapter is tested on macOS 27 and iOS 26.5 simulator. The NIO client has loopback
  protocol and TLS coverage on Linux, macOS 27 and iOS 26.5 simulator, including the approved
  NIO 2.102.0 / NIOSSL 2.37.4 minimums. Android WebSocket execution, system-root discovery in an
  Android app, other Apple platforms and physical devices remain unqualified.

## Products

HTTPCore depends on nothing in this package. WebSocketCore depends on HTTPCore, and HTTPTesting
depends on both cores. The WebSocket adapter targets depend on WebSocketCore; HTTP transports
retain their existing HTTPCore dependency.

| Product | What it is |
|---|---|
| `HTTPCore` | The client, request and response types, the error model, and the streaming decoders. No `URLSession`. |
| `HTTPPortable` | The AsyncHTTPClient transport, buffered and streaming, behind the `HTTPPortable` trait. |
| `HTTPTesting` | HTTP fixtures, mocks and clocks, plus `MockWebSocketTransport`, `ScriptedWebSocketConnection`, and `WebSocketRendezvous`. |
| `HTTPURLSession` | The `URLSession` transport, buffered and streaming. |
| `WebSocketCore` | Injected client, bounded receive/send queues, synchronous submission, shared completion, graceful close and backend protocols. |
| `WebSocketHummingbird` | Independently trait-gated server adapter scaffolding; no live adapter yet. |
| `WebSocketPortable` | NIO/NIOSSL client with bounded framing and explicit transport shutdown, behind the `WebSocketPortable` trait. |
| `WebSocketURLSession` | Apple WebSocket client using an owned URLSession. |

### WebSocket connection ownership

`WebSocketClient(transport:)` accepts a backend and an optional injected clock. Use
`connect(to:options:)` for an independently owned connection or `withConnection(to:options:operation:)`
for a result-returning scope that aborts on exit. Both also accept a `WebSocketRequest`.
The socket, messages value and iterators retain the connection; the final external owner releases it.

One iterator claims reading on its first `next()`. Its copies share that claim and reject overlapping
reads. Cancellation releases the pending read and claim while preserving unread messages for a new
iterator. Ordinary reader and ping-caller cancellation leave the connection healthy.
A ping already admitted keeps its original deadline after caller cancellation; missing its pong
terminates the connection. There is no automatic heartbeat or reconnect.

Defaults are configurable through `WebSocket.Options`: 1 MiB per message, a 1 MiB / 16-message inbox,
30 seconds for connecting, 10 seconds for ping, and 5 seconds for bounded close attempts. Text counts
UTF-8 bytes and empty messages count toward capacity. Overflow is terminal and attempts a bounded
policy close before aborting when no data write or close frame is active; otherwise it aborts directly.
These bounds exclude backend buffers and copies.
Backend-reported closure drains the inbox; terminal failures discard it.

### WebSocket sending and close

`send` and synchronous `enqueue` accept `String`, `Data`, or `WebSocket.Message` through one bounded
FIFO. Sequential enqueue calls establish order immediately; concurrent producers are ordered at
admission. Neither entry point waits for capacity. Defaults allow 16 active-plus-queued messages and
1 MiB of payload, with a configurable 30-second `sendTimeout` covering queue residence and writing.

`sendPolicy` defaults to `.serialize`; `.rejectOverlapping` instead rejects while a send is
outstanding. `sendFailurePolicy` defaults to `.preserveIfUnsent`, which removes only an unstarted
failed send; `.abortConnection` also prevents later dependent messages from starting. Failure after
writing begins always aborts because part of the message may already have reached the peer.
Both policies have per-call overrides. Capacities and deadlines come from options captured at connect.

```swift
func sendUpdates(on socket: WebSocket) async throws {
  let first = try socket.enqueue("first")
  let second = try socket.enqueue("second", policy: .serialize)
  try await first.wait()
  try await second.wait()
  try await socket.send("last", failurePolicy: .abortConnection)
  try await socket.close()
}
```

A `SendOperation` supports multiple waiters and repeatable results. Cancelling a `wait()` detaches
only that waiter; `operation.cancel()` cancels the send using its failure policy. Cancelling async
`send` cancels its operation. Dropping an operation does not cancel it, and retaining one does not
keep the socket alive. Keep a socket owner until the work ends.

Write completion is not an application acknowledgement or proof of remote execution. Dependent
commands still need application ordering and acknowledgements; independent updates can handle
rejection or coalesce before submission.

`close()` stops admission, rejects queued sends, waits for the active write and then sends the
close frame. Repeated calls share the first valid code, reason and deadline, including the active-write
wait. Reasons are limited to 123 UTF-8 bytes. After admission, cancellation defaults to `.stopWaiting`,
leaving the close running; `close(cancellation: .abortConnection)` aborts for every waiter instead.
Pre-cancelled calls start nothing. Timeout aborts the connection and releases all waiters.

Use the Apple adapter through the same injected client:

```swift
import WebSocketCore
import WebSocketURLSession

let client = WebSocketClient(transport: URLSessionWebSocketTransport())
try await client.withConnection(to: endpoint) { socket in
  try await socket.send("subscribe")
  for try await message in socket.messages {
    handle(message)
  }
}
```

The adapter refuses redirects and automatic credential/cookie storage. It uses system TLS trust
validation, preserves available failed-upgrade status, and delegates authentication replay to the
shared client. Foundation can retry connection establishment internally; one adapter attempt creates
one URLSession task. Unknown HTTP status never triggers credential refresh.

close() requests orderly shutdown and awaits backend completion within closeTimeout.
Its result and closeInfo are backend-reported metadata, which can reflect our locally requested
code and reason. Success does not prove a peer close acknowledgement or application delivery.

The shared limits bound our queues. Foundation's internal buffers, TCP/TLS buffers and temporary
copies are outside that accounting. The Hummingbird adapter remains scaffolding.

### Portable WebSocket connections

Enable the `WebSocketPortable` dependency trait and add the product of the same name to your target.
Use one reusable transport and explicitly shut it down after its clients finish:

```swift
import WebSocketCore
import WebSocketPortable

let transport = try NIOWebSocketTransport()
let client = WebSocketClient(transport: transport)
do {
  try await client.withConnection(to: endpoint) { socket in
    try await socket.send("subscribe")
    for try await message in socket.messages {
      handle(message)
    }
  }
} catch {
  try? await transport.shutdown()
  throw error
}
try await transport.shutdown()
```

Shutdown refuses new connects, aborts pending and open channels, waits for their release, and then
shuts down the owned event-loop group. Repeated calls share that cleanup. Individual socket
cancellation leaves the transport reusable.

NIOSSL validates certificates and hostnames with its default platform trust roots. The adapter refuses
redirects, unsolicited subprotocols and extensions. It shares the core's inbox and send policies.
Incoming messages use the configured byte bound plus a 1,024-fragment safety limit. Opening responses
are capped at 16 KiB including the status line and at 100 fields. Resource exhaustion reports
bufferOverflow or messageTooLarge; malformed protocol input reports protocolViolation.
Pings continue to be processed while application messages remain unread. A full inbox is terminal;
TCP/TLS buffers and temporary frame copies remain outside the inbox accounting.

The [WebSocketPortable guide](Sources/WebSocketPortable/WebSocketPortable.docc/WebSocketPortable.md)
describes these limits and platform qualification.

### Scripted WebSocket support

Scripts return exactly the supplied outcomes. They do not implement authentication, retries,
queue limits, or connection lifecycle policy:

```swift
import HTTPTesting
import WebSocketCore

let connection = ScriptedWebSocketConnection(steps: [
  .init(result: .success(.message(.text("hello")))),
  .init(result: .failure(WebSocketError(kind: .sendQueueFull))),
])
let first = try await connection.perform(.receive)
```

Use `WebSocketRendezvous` to await an operation's arrival and release it without sleeps.
An exhausted script records the call and throws `WebSocketScriptFailure.noScriptedOutcome`
inside a `WebSocketError`. The scripts conform to the backend protocols, so they can exercise the
shared client and lifecycle. They do not establish live network compatibility.

## Documentation

The published API reference for `HTTPCore`, `HTTPURLSession`, and `HTTPTesting` is at
**[kalebcooper.github.io/swifty-networking](https://kalebcooper.github.io/swifty-networking/documentation/)**,
rebuilt from `main` on every push to it. Nine articles accompany it:

| Article | |
|---|---|
| [Getting Started](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/gettingstarted/) | Build a client, send a body, and choose a `URLSession` |
| [Authenticating a Request](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/authenticating/) | Attaching a credential, refreshing it, and what makes two credentials one |
| [Request Policies](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/requestpolicies/) | Deadlines, retries and `Retry-After`, redirects, and coalescing |
| [Concurrency Posture](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/concurrencyposture/) | How the package uses isolation, shared state, and typed throws |
| [The Error Model](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/errormodel/) | `TransportError`, its cases, and decoding a server's error envelope |
| [Streaming a Response](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/streaming/) | `stream(_:)`, `LineSplitter`, `NDJSONDecoder`, `SSEDecoder`, and `EventSource` |
| [Paginating a Response](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/paginating/) | `pages(_:as:next:)`, following a `Link` header or a body cursor, and `WebLink` |
| [Testing](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/testing/) | `MockTransport`, `RecordingClock`, `RecordingObserver`, and `StubURLProtocol` |
| [Bridging Observable State to Request Replay](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/observations/) | Driving a request from an `@Observable` model with `Observations` |

The [WebSocketCore reference](Sources/WebSocketCore/WebSocketCore.docc/WebSocketCore.md)
describes the unreleased connection API, backend contract and current limits. The
[WebSocketURLSession guide](Sources/WebSocketURLSession/WebSocketURLSession.docc/WebSocketURLSession.md)
describes the Apple adapter and its qualification limits.

Or build them locally in Xcode with **Product ▸ Build Documentation**. `HTTPPortable`'s reference
builds from its own catalog with the trait enabled; the site does not carry it. `LoggingObserver` is
the same: it is in `HTTPCore`'s reference only when the `Logging` trait is enabled.

## License

MIT. See [LICENSE](LICENSE).
