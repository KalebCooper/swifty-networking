// `URLSessionTransport` exists only where URLSession does, so this suite compiles away on other
// platforms.
#if canImport(Darwin)

import Foundation
import HTTPCore
import HTTPTesting
import HTTPTypes
import HTTPURLSession
import Synchronization
import Testing

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

/// A server that refuses every token but `token`, and answers the first request that carries it with
/// a `URLError`, so one request crosses a refresh, a replay, and a retry in that order.
private func origin(accepting token: String, answering body: Data)
  -> @Sendable (URLRequest) -> StubURLProtocol.Answer
{
  let accepted = Counter()
  return { request in
    guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else {
      return .response(body: Data(), headers: [:], status: 401)
    }
    guard accepted.next > 1 else { return .failure(code: .timedOut, failingURL: nil) }
    return .response(body: body, headers: ["Content-Type": "application/json"], status: 200)
  }
}

/// The `Authorization` values the loading system saw, in send order; `nil` where a request carried
/// none.
private func authorizations(of script: StubURLProtocol.Script) -> [String?] {
  script.requests.map { $0.request.value(forHTTPHeaderField: "Authorization") }
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

/// The failure events in order.
private func failed(_ events: [RecordingObserver.Event]) -> [FailureEvent] {
  events.compactMap { if case .failed(let event) = $0 { event } else { nil } }
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
private let url = URL.fixture("https://api.example.com/people/1")

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct URLSessionEndToEndTests {
  @Test func refreshReplayThenRetry() async throws {
    let clock = RecordingClock()
    let observer = RecordingObserver(bodyPreviewLimit: 4)
    let script = StubURLProtocol.Script()
    script.setHandler(forPath: path, handler: origin(accepting: "t2", answering: body))
    let session = URLSession(configuration: script.makeSessionConfiguration())
    defer { session.finishTasksAndInvalidate() }
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let client = HTTPClient(
      authentication: Authentication(provider: tokens, refresher: tokens),
      baseURL: URL.fixture("https://api.example.com"),
      clock: clock,
      correlationIDGenerator: { correlationID },
      observer: observer,
      retryPolicy: RetryPolicy(
        backoff: BackoffSchedule(delays: [backoff, .milliseconds(50)]), maxAttempts: 2),
      transport: URLSessionTransport(session: session)
    )

    // One backoff, answered once the client is parked on it. Every other suspension here is a load,
    // which `StubURLProtocol` answers before it returns.
    let call = Task { () async throws -> Person in try await client.execute(Request(path: path)) }
    await clock.waitForPendingSleep()
    clock.advanceAll()
    let person = try await call.value

    #expect(person.name == "Ada")
    #expect(tokens.refreshes == 1)
    #expect(clock.sleeps == [backoff])
    #expect(authorizations(of: script) == ["Bearer t1", "Bearer t2", "Bearer t2"])
    #expect(
      shape(observer.events) == [
        "sent(1)", "received(1:401)", "sent(1)", "failed(1)", "sent(2)", "received(2:200)",
      ])
    #expect(correlationIDs(observer.events) == Array(repeating: correlationID, count: 6))
    #expect(failed(observer.events).map(\.failure.isTimeout) == [true])
    #expect(failed(observer.events).first?.url == url)
  }
}

#endif
