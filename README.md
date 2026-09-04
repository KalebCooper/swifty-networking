# swifty-networking

[![CI](https://github.com/KalebCooper/swifty-networking/actions/workflows/ci.yml/badge.svg)](https://github.com/KalebCooper/swifty-networking/actions/workflows/ci.yml)
[![Docs](https://github.com/KalebCooper/swifty-networking/actions/workflows/docs.yml/badge.svg)](https://kalebcooper.github.io/swifty-networking/documentation/)
[![Swift Version Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKalebCooper%2Fswifty-networking%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/KalebCooper/swifty-networking)
[![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKalebCooper%2Fswifty-networking%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/KalebCooper/swifty-networking)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Swift networking package built on Swift concurrency. Build one client, describe a request, and get
back a decoded value, a raw response, or a stream of bytes, with a single typed error to handle and
test support included.

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
- Redirects under a policy: `follow`, `sameOrigin`, or `never`, per client or per request, with the
  credential the client attached kept off any hop to another origin, and every hop reported to the
  observer. A transport never follows one on its own.
- Typed errors: every call throws `TransportError` and nothing else.
- Streaming as `AsyncSequence`: `stream(_:)` hands back a `StreamedBody`, a sequence of `Data`
  chunks, and the line splitting, NDJSON, and Server-Sent Events decoders each read one directly.
  `events(_:)` reconnects a Server-Sent Events stream on its own, carrying `Last-Event-ID` and
  waiting the server's `retry` on the client's clock.
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
.package(url: "https://github.com/KalebCooper/swifty-networking.git", from: "1.0.0")
```

Add `HTTPCore` to any target that builds requests, `HTTPURLSession` to the one that sends them on Apple
platforms, `HTTPPortable` to the one that sends them on Linux and on Android, and `HTTPTesting` to your
test targets. `HTTPPortable` is behind a trait of the same name, so enable it on the dependency:

```swift
.package(url: "https://github.com/KalebCooper/swifty-networking.git", from: "1.0.0",
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

Every call throws `TransportError`, so a `catch` binds the typed error and a status outside `2xx`
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
is part of the answer: an `ETag` to send back, a pagination cursor, a rate-limit budget.

```swift
let page: DecodedResponse<[Item]> = try await client.execute(Request(path: "/items"))
print(page.value.count, page.headers[.eTag] ?? "", page.status.code)
```

One method name, three results: `execute(_:)` returns a decoded value, a `DecodedResponse`, or the
raw `Response`, and the type you annotate decides which.

### Authenticating with refresh

A `TokenProvider` supplies the current token and a `TokenRefresher` replaces it. An `Authentication`
pairs the two with the rules around them: the client attaches the token on every send and, on a
`401`, refreshes once and replays the request once, and a `refreshThreshold` makes it refresh before
a send when the provider reports a lifetime at or below it.

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
without the field the client attached, whichever field `Authentication.scheme` names. Twenty hops are
followed, and every one is a send the observer sees.

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

## Products

`HTTPCore` depends on nothing in this package. The other three depend on it.

| Product | What it is |
|---|---|
| `HTTPCore` | The client, request and response types, the error model, and the streaming decoders. No `URLSession`. |
| `HTTPURLSession` | The `URLSession` transport, buffered and streaming. |
| `HTTPPortable` | The AsyncHTTPClient transport, buffered and streaming, behind the `HTTPPortable` trait. |
| `HTTPTesting` | `MockTransport`, `RecordingClock`, `RecordingObserver`, `RecordingTokenProvider`, `StubURLProtocol`, and response fixtures. |

## Documentation

The API reference for `HTTPCore`, `HTTPURLSession`, and `HTTPTesting` is at
**[kalebcooper.github.io/swifty-networking](https://kalebcooper.github.io/swifty-networking/documentation/)**,
rebuilt from `main` on every push to it. Eight articles accompany it:

| Article | |
|---|---|
| [Getting Started](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/gettingstarted/) | Build a client, send a body, and choose a `URLSession` |
| [Authenticating a Request](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/authenticating/) | Attaching a credential, refreshing it, and what makes two credentials one |
| [Request Policies](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/requestpolicies/) | Deadlines, retries and `Retry-After`, redirects, and coalescing |
| [Concurrency Posture](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/concurrencyposture/) | How the package uses isolation, shared state, and typed throws |
| [The Error Model](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/errormodel/) | `TransportError`, its cases, and decoding a server's error envelope |
| [Streaming a Response](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/streaming/) | `stream(_:)`, `LineSplitter`, `NDJSONDecoder`, `SSEDecoder`, and `EventSource` |
| [Testing](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/testing/) | `MockTransport`, `RecordingClock`, `RecordingObserver`, and `StubURLProtocol` |
| [Bridging Observable State to Request Replay](https://kalebcooper.github.io/swifty-networking/documentation/httpcore/observations/) | Driving a request from an `@Observable` model with `Observations` |

Or build them locally in Xcode with **Product ▸ Build Documentation**. `HTTPPortable`'s reference
builds from its own catalog with the trait enabled; the site does not carry it. `LoggingObserver` is
the same: it is in `HTTPCore`'s reference only when the `Logging` trait is enabled.

## License

MIT. See [LICENSE](LICENSE).
