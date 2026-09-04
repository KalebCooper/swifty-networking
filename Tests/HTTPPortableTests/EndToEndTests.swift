// `AsyncHTTPClientTransport` exists only behind the `HTTPPortable` trait, so this suite compiles
// away without it.
#if HTTPPortable

import Foundation
import HTTPCore
import HTTPPortable
import HTTPTesting
import HTTPTypes
import NIOHTTP1
import Testing

/// The `Authorization` values the server saw, in send order; `nil` where a request carried none.
private func authorizations(of script: Script) -> [String?] {
  script.requests.map { $0.header("Authorization") }
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

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct AsyncHTTPClientEndToEndTests {
  @Test(
    "A 401 refreshes and replays, a closed connection retries, and the second attempt decodes the body"
  )
  func refreshReplayThenRetry() async throws {
    let clock = RecordingClock()
    let observer = RecordingObserver(bodyPreviewLimit: 4)
    // A 401 for the first token, a closed connection for the replay, then the answer: the script
    // decides nothing, and the assertions below are what check which token each request carried.
    let script = Script(answers: [
      .response(status: 401),
      .close,
      .response(chunks: [body], headers: [("Content-Type", "application/json")], status: 200),
    ])
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    // The origin closes the connection on the attempt it drops, so the failure the retry policy
    // replays arrives at once and nothing here waits on the wall clock.
    try await withLoopback(script) { server, transport in
      let baseURL = try #require(URL(string: "http://\(server.authority)"))
      let client = HTTPClient(
        authentication: Authentication(provider: tokens, refresher: tokens),
        baseURL: baseURL,
        clock: clock,
        correlationIDGenerator: { correlationID },
        observer: observer,
        retryPolicy: RetryPolicy(
          backoff: BackoffSchedule(delays: [backoff, .milliseconds(50)]), maxAttempts: 2,
          retryable: { _ in true }),
        transport: transport
      )

      // One backoff, answered once the client is parked on it. Every other suspension here is a
      // load the origin answers, or the one it closes on.
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
      #expect(failed(observer.events).map { transportFailure($0.failure)?.0 } == [.connectivity])
      #expect(failed(observer.events).first?.url == baseURL.appending(path: path))
    }
  }
}

#endif
