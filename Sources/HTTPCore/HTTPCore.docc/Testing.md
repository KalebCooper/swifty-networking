# Testing

Drive a whole client from a test with no network, no sleeping, and no shared global state.

## Overview

The test types ship as a real product, `HTTPTesting`, so an app that builds a client over ``Transport``
gets the same test types the package's own tests use. There are five of them and one set of
fixtures.

| Type | Stands in for | Portable |
|---|---|---|
| `MockTransport` | ``Transport``, answering from a queue or a per-path handler | yes |
| `RecordingClock` | the client's `Clock`, recording sleeps and resuming them on demand | yes |
| `RecordingObserver` | ``TransportObserver``, with one ordered event log | yes |
| `RecordingTokenProvider` | ``TokenProvider`` and ``TokenRefresher``, counting the refreshes asked for | yes |
| `StubURLProtocol` | the loading system under a real `URLSession` | Apple platforms only |

Each one is a `Sendable` `final class` over a single `Mutex`, never an `actor`, for the same reason
nothing else in the package is one: the protocols they conform to are synchronous, and an actor
would put a hop in front of a credential read or an observer report.

## A Whole Client, No Network and No Waiting

The two collaborators that make an integration test deterministic are the transport and the clock.
Seed the first with the exact sequence of answers the scenario needs, and drive the second by hand,
so a retry that would sleep for ten milliseconds of real time parks until the test says otherwise
and the delay becomes a value to assert.

```swift
import HTTPCore
import HTTPTesting
import Testing

struct Profile: Decodable, Sendable {
  let name: String
}

@Test func retriesOnceAfterATimeout() async throws {
  let clock = RecordingClock()
  let observer = RecordingObserver()
  let transport = MockTransport(results: [
    .failure(.transport(kind: .timedOut, underlying: nil)),
    .success(.ok(json: Fixtures.jsonObject(["name": "Ada"]))),
  ])

  let client = HTTPClient(
    baseURL: URL(string: "https://api.example.com")!,
    clock: clock,
    observer: observer,
    retryPolicy: RetryPolicy(
      backoff: BackoffSchedule(delays: [.milliseconds(10)]), maxAttempts: 2
    ),
    transport: transport
  )

  async let profile: Profile = client.execute(Request(path: "/me"))

  await clock.waitForPendingSleep()
  clock.advanceAll()

  #expect(try await profile.name == "Ada")
  #expect(clock.sleeps == [.milliseconds(10)])
  #expect(transport.requests.count == 2)
  #expect(observer.events.count == 4)
}
```

`await clock.waitForPendingSleep()` then `clock.advanceAll()` is the handshake, and the order
matters: waiting first guarantees the sleeper has registered, so the test is not racing the client
into the clock. Advance one deadline at a time whenever one sleeper must finish before another.
Resume order within a single advance is deadline order, but which resumed task runs first belongs to
the executor, and on the simulator it is not registration order.

## Answering Requests

`MockTransport` answers from a FIFO queue seeded by `init(answers:results:)` and `enqueue(_:)`, or
from a handler registered for a path with `setHandler(forPath:handler:)`. A handler for the request's
path always wins, and a request with no path falls to the queue. A handler is called once per matching
request, so one registration serves a burst of concurrent callers, which is what a coalescing or
single-flight test needs.

One queue and one handler table serve both surfaces, and a `MockTransport.Answer` is what each holds:
a status, header fields, and a body built afresh for every delivery, which is why one seeded answer
serves a whole burst and each caller reads the body whole. `init(answers:results:)` takes a
``Response`` in its `results` as readily as an `Answer` in its `answers`, wrapping each response in
an answer that delivers its body as a single chunk and queueing `results` ahead of `answers`.
`enqueue(_:)` takes an `Answer`, so a response reaching the queue later is wrapped with
`MockTransport.Answer(_:)` at the call site.

The key is the path without its query string. A request built as
`Request(path: "/me", query: [QueryItem(name: "x", value: "1")])` reaches the transport with the
target `/me?x=1`, and the handler registered for `/me` answers it; a `MockTransport` key that itself
contains a `?` matches nothing. The handler is handed the request as it arrived, so a handler that
varies its answer by query reads the query from there.
`StubURLProtocol.Script.setHandler(forPath:handler:)` keys its handlers the same way, and compares
the key against the path with percent-encoding removed, so a key that contains a `?` matches only a
request whose path carries that `?` percent-encoded.

Every call is logged whether or not it was answered, so `requests.count` reads as calls made and
`last` is the newest. `reset()` returns it to freshly-constructed state: queue, handlers, and
log alike. Exhausting the queue is not a hang and not a `fatalError`; it throws
`.transport(kind: .other, underlying: MockTransportFailure.noCannedResponse)`, and that failure type
is public so a test can assert on it instead of on a string.

Resolving an answer suspends nowhere, so `MockTransport` checks no cancellation on the way to one.
Reading the body does: a ``StreamedBody`` refuses a cancelled task, so a call read under cancellation
fails with ``TransportError/cancelled``, which is where a live transport reports it too.

## Streaming a Body

`MockTransport` answers ``Transport/stream(_:body:options:)`` from the seeding a send is answered
from, so a client built over it streams and no second transport is needed. Running out is the same
failure, `MockTransportFailure` `noCannedResponse`. ``Transport/send(_:body:options:)`` is the
protocol's default over `stream`, so a buffered call takes the answer at the head of the queue, or
the handler's, and is recorded in `requests` once.

A `MockTransport.Answer` carries the status and the header fields the response arrives with, and a
body seeded either as chunks or as a ``StreamedBody`` the test builds. Seeding a failure alongside
the chunks is what puts a mid-stream failure under test: the chunks arrive first and the failure ends
the sequence, which is the shape a live transport reports a dropped connection in.

```swift
let transport = MockTransport(answers: [
  .success(
    MockTransport.Answer(
      chunks: [Data("data: one\n\n".utf8), Data("data: two\n\n".utf8)],
      failure: .transport(kind: .timedOut, underlying: nil),
      headers: [.contentType: "text/event-stream"]))
])
let client = HTTPClient(
  baseURL: URL(string: "https://api.example.com")!,
  transport: transport
)

let body = try await client.stream(Request(path: "/events"))
```

The body is handed over exactly as it was seeded, each chunk as one element, an empty one included,
so a test places a chunk boundary exactly where it wants one, inside a line or between two, and
nothing is wrapped a second time on the way out. The transport starts nothing of its own: a caller
that drops the sequence unread leaves nothing running behind it. A body that must neither deliver
nor end, to park a consumer and cancel it, is the case for the `Answer` initializer that takes a
closure: build the sequence in the test, hold the continuation that feeds it, and the body stays
parked for as long as the test holds it.

## Reading What the Client Reported

`RecordingObserver` appends every event to one ordered log as a nested `Event` enum: `failed`,
`finishedBody`, `received`, `sent`. Because the client reports a send and not an attempt, the log is
what tells a `401` refresh-and-replay, which is two sends carrying the same attempt ordinal, apart
from a retry, which is two sends with different ones. Its `bodyPreviewLimit` is stored from
`init(bodyPreviewLimit:)` and returned through the protocol requirement, so a test drives
``TransportObserver/bodyPreview(of:)`` through the same instance a client would.

## Standing In for a Credential Source

`RecordingTokenProvider` conforms to both ``TokenProvider`` and ``TokenRefresher``, so an
``Authentication`` over the same instance as both is the whole configuration for an authenticated
test, and the test reads what the client did to it. It holds the token it was seeded with, hands it
out through ``TokenProvider/currentToken()``, and answers each ``TokenRefresher/refresh()`` with
the next seeded outcome: a success installs its token, a failure throws the ``TransportError`` it
carries and leaves the credential exactly as it was. Both are counted, so `refreshes` reads as
refreshes asked for.

```swift
let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
let transport = MockTransport()
transport.setHandler(forPath: "/me") { request in
  request.headerFields[.authorization] == "Bearer t2"
    ? .success(.empty()) : .success(.empty(status: .unauthorized))
}
let client = HTTPClient(
  authentication: Authentication(provider: tokens, refresher: tokens),
  baseURL: URL(string: "https://api.example.com")!,
  transport: transport
)

try await client.executeExpectingNoContent(Request(path: "/me"))

#expect(tokens.refreshes == 1)
```

Seed a `timeUntilExpiry` to put ``Authentication/refreshThreshold`` under test: a lifetime at or below
the threshold is what makes the client refresh before it sends, and `refreshLifetime` is what a
successful refresh installs in its place. `install(timeUntilExpiry:token:)` replaces the credential
from the outside, which is how a test stands in for another caller's refresh landing mid-request. A
refresh with nothing left to take fails with `RecordingTokenProviderFailure.noSeededOutcome`, the
same seeding-mistake signal `MockTransport` gives.

## Fixtures

`Fixtures.json(_:)` runs an `Encodable` value through a `JSONEncoder` with sorted keys, so the bytes
are deterministic and a test can compare them directly. `Fixtures.jsonObject(_:)` writes a flat JSON
object straight from a `KeyValuePairs<String, String>` with no encoder at all. ``Response`` gains
four static builders, `empty(headers:status:)`, `json(_:headers:status:)`, `ok(headers:json:)`, and
`text(_:headers:status:)`, which add the matching `Content-Type` only when the header fields do not
already carry one.

## Testing the Real Transport

`StubURLProtocol` answers under a genuine `URLSession`, so the request under test goes through the
actual `URLRequest` conversion, the actual upload-versus-data choice, and the actual `URLError`
mapping. It is the one Apple-only file in `HTTPTesting`: the whole file sits inside
`#if canImport(Darwin)`, so Linux and Android compile it out and the rest of the product stays
portable.

The answers live on a `Script` the test holds, not on the protocol instance the loading system
mints.

```swift
let script = StubURLProtocol.Script(answers: [
  .response(body: Data(), headers: [:], status: 401),
  .failure(code: .timedOut, failingURL: nil),
  .response(body: Fixtures.jsonObject(["name": "Ada"]), headers: [:], status: 200),
])

let transport = URLSessionTransport(
  session: URLSession(configuration: script.makeSessionConfiguration())
)
```

`makeSessionConfiguration()` returns an ephemeral configuration carrying the script's own token in
`httpAdditionalHeaders`, and a process-wide table routes each request back to the script that owns
it. That keeps parallel tests isolated without a `.serialized` suite, and it is why `canInit(with:)`
answers `true` only for a token-carrying request, so a live request is never swallowed by a stub
someone forgot to tear down.

Seeding mirrors `MockTransport`: a FIFO queue, a path-keyed handler that wins over it, a `requests`
log of `Call` values carrying the body, `last`, and `reset()`. There is no delay knob, because the
client owns time through its injected clock and a stub that slept would make every test using it
slow. An unanswered request fails with the public `StubURLProtocolFailure`, which is read back with
`StubURLProtocolFailure(error)` and not with a cast: the loading system rebuilds the error as a
plain `NSError` on its way out, so the type is recovered through its `CustomNSError` domain and
code.

> Note: Hold the script for the whole test. Its `deinit` drops the entry from the routing
> table, so a script that goes out of scope mid-flight unregisters its own answers.

## Testing a Pipeline Without a Client

A decoder needs chunks, not a client. Wrap an `AsyncStream<Data>` in a ``StreamedBody`` and feed
``LineSplitter``, ``NDJSONDecoder``, or ``SSEDecoder`` directly, and the test states what the
chunks frame into with nothing else in the way, with a chunk boundary placed wherever the case
needs one. Reach for `MockTransport` when the client is the thing
under test: how it attaches a credential, what it does with a status, and what a caller sees when a
body fails part-way through.
