import HTTPCore
import HTTPTesting
import HTTPTypes
import Synchronization
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A counter a `@Sendable` closure can share. `Mutex` is noncopyable and cannot be captured by value,
/// so a reference type wraps it.
private final class Counter: Sendable {
  private let count = Mutex(0)

  /// The next value, counting from `1`.
  var next: Int {
    count.withLock {
      $0 += 1
      return $0
    }
  }
}

/// A server that refuses every token but `token`, and times out the first request that carries it, so
/// one request crosses a refresh, a replay, and a retry in that order.
private func origin(accepting token: String, answering body: Data)
  -> @Sendable (HTTPRequest) -> Result<MockTransport.Answer, TransportError>
{
  let accepted = Counter()
  return { request in
    guard request.headerFields[.authorization] == "Bearer \(token)" else {
      return .success(MockTransport.Answer(.empty(status: .unauthorized)))
    }
    guard accepted.next > 1 else { return .failure(timeout) }
    return .success(MockTransport.Answer(.ok(json: body)))
  }
}

/// The `Authorization` values the transport saw, in send order; `nil` where a request carried none.
private func authorizations(of transport: MockTransport) -> [String?] {
  transport.requests.map { $0.request.headerFields[.authorization] }
}

/// The identifier every event carried, in order.
private func correlationIDs(_ events: [RecordingObserver.Event]) -> [String] {
  events.map { event in
    switch event {
    case .failed(let failure): failure.correlationID
    case .finishedBody(let body): body.correlationID
    case .received(let response): response.correlationID
    case .sent(let request): request.correlationID
    }
  }
}

/// The response events in order.
private func received(_ events: [RecordingObserver.Event]) -> [ResponseEvent] {
  events.compactMap { if case .received(let event) = $0 { event } else { nil } }
}

/// The request events in order.
private func sent(_ events: [RecordingObserver.Event]) -> [RequestEvent] {
  events.compactMap { if case .sent(let event) = $0 { event } else { nil } }
}

/// The log reduced to what each event is and which attempt it belongs to.
private func shape(_ events: [RecordingObserver.Event]) -> [String] {
  events.map { event in
    switch event {
    case .failed(let failure): "failed(\(failure.attempt))"
    case .finishedBody(let body): "finishedBody(\(body.bytesReceived))"
    case .received(let response): "received(\(response.attempt):\(response.status.code))"
    case .sent(let request): "sent(\(request.attempt))"
    }
  }
}

/// The value the successful body decodes to.
private struct Person: Decodable {
  let name: String
}

private let backoff = Duration.milliseconds(10)
private let body = Fixtures.jsonObject(["name": "Ada"])
private let correlationID = "e2e-1"
private let path = "/people/1"
private let timeout = TransportError.transport(kind: .timedOut, underlying: nil)
private let url = URL.fixture("https://api.example.com/people/1")

@Suite("HTTPClient end to end", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct EndToEndTests {
  @Test("a 401 refreshes and replays, a timeout retries, and the second attempt decodes the body")
  func refreshReplayThenRetry() async throws {
    let clock = RecordingClock()
    let observer = RecordingObserver(bodyPreviewLimit: 4)
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: path, handler: origin(accepting: "t2", answering: body))
    let client = HTTPClient(
      authentication: Authentication(provider: tokens, refresher: tokens),
      baseURL: URL.fixture("https://api.example.com"),
      clock: clock,
      correlationIDGenerator: { correlationID },
      observer: observer,
      retryPolicy: RetryPolicy(
        backoff: BackoffSchedule(delays: [backoff, .milliseconds(50)]), maxAttempts: 2),
      transport: transport
    )

    // One backoff, answered once the client is parked on it. A wait that never arrives hangs instead
    // of being skipped.
    let call = Task { () async throws -> Person in try await client.execute(Request(path: path)) }
    await clock.waitForPendingSleep()
    clock.advanceAll()
    let person = try await call.value

    #expect(person.name == "Ada")
    #expect(tokens.refreshes == 1)
    #expect(clock.sleeps == [backoff])
    #expect(authorizations(of: transport) == ["Bearer t1", "Bearer t2", "Bearer t2"])
    #expect(
      shape(observer.events) == [
        "sent(1)", "received(1:401)", "sent(1)", "failed(1)", "sent(2)", "received(2:200)",
      ])
    #expect(correlationIDs(observer.events) == Array(repeating: correlationID, count: 6))
    #expect(sent(observer.events).allSatisfy { $0.authAttached && $0.method == .get })
    #expect(sent(observer.events).allSatisfy { $0.url == url })
    #expect(received(observer.events).last?.bodyPreview == Data(body.prefix(4)))
  }

  @Test(
    "a streamed body read to its end reports its send, its response, and its end under one identifier"
  )
  func streamReportsItsEnd() async throws {
    let observer = RecordingObserver()
    let transport = MockTransport(answers: [
      .success(MockTransport.Answer(chunks: [Data("Ada".utf8), Data(" Lovelace".utf8)]))
    ])
    let client = HTTPClient(
      baseURL: URL.fixture("https://api.example.com"),
      correlationIDGenerator: { correlationID },
      observer: observer,
      transport: transport
    )

    var collected = Data()
    for try await chunk in try await client.stream(Request(path: path)) {
      collected.append(chunk)
    }

    #expect(collected == Data("Ada Lovelace".utf8))
    #expect(shape(observer.events) == ["sent(1)", "received(1:200)", "finishedBody(12)"])
    #expect(correlationIDs(observer.events) == Array(repeating: correlationID, count: 3))
  }
}
