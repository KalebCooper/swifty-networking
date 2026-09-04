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

/// Compile-time check that a type is `Sendable`.
private func requireSendable<T: Sendable>(_: T.Type) {}

/// An error the tests pass as an underlying error.
private struct ProbeError: Error {}

/// An observer that implements no requirement and inherits every default.
private struct Silent: TransportObserver {}

/// An observer that logs one entry per event behind a `Mutex`.
private final class Recorder: TransportObserver, Sendable {
  private let log = Mutex<[String]>([])
  private let limit: Int?

  init(bodyPreviewLimit: Int? = nil) {
    self.limit = bodyPreviewLimit
  }

  var bodyPreviewLimit: Int? { limit }
  var entries: [String] { log.withLock { $0 } }

  func didFail(_ event: FailureEvent) { log.withLock { $0.append("fail:\(event.attempt)") } }
  func didFinishBody(_ event: BodyEvent) {
    log.withLock { $0.append("body:\(event.bytesReceived)") }
  }
  func didReceive(_ event: ResponseEvent) { log.withLock { $0.append("receive:\(event.attempt)") } }
  func willSend(_ event: RequestEvent) { log.withLock { $0.append("send:\(event.attempt)") } }
}

/// An observer that implements only `didFinishBody(_:)` and inherits the other three defaults.
private final class BodyOnly: TransportObserver, Sendable {
  private let log = Mutex<[String]>([])

  var entries: [String] { log.withLock { $0 } }

  func didFinishBody(_ event: BodyEvent) {
    log.withLock { $0.append("body:\(event.bytesReceived)") }
  }
}

/// An observer that implements only `didFail(_:)` and inherits the other three defaults.
private final class FailureOnly: TransportObserver, Sendable {
  private let log = Mutex<[String]>([])

  var entries: [String] { log.withLock { $0 } }

  func didFail(_ event: FailureEvent) { log.withLock { $0.append("fail:\(event.attempt)") } }
}

private let correlationID = "8b1f"
private let url = URL.fixture("https://example.com/a")

private func request(attempt: Int) -> RequestEvent {
  RequestEvent(
    attempt: attempt, authAttached: true, correlationID: correlationID, method: .get, url: url)
}

private func response(attempt: Int) -> ResponseEvent {
  ResponseEvent(
    attempt: attempt, authAttached: true, correlationID: correlationID, duration: .milliseconds(10),
    method: .get, status: .ok, url: url)
}

private func bodyEnd(bytes: Int) -> BodyEvent {
  BodyEvent(bytesReceived: bytes, correlationID: correlationID)
}

private func failure(attempt: Int) -> FailureEvent {
  FailureEvent(
    attempt: attempt, authAttached: true, correlationID: correlationID, duration: .milliseconds(10),
    failure: .transport(kind: .timedOut, underlying: ProbeError()), method: .get, url: url)
}

/// A body of `count` bytes, each byte its own index modulo 256.
private func body(count: Int) -> Data {
  Data((0..<count).map { UInt8($0 % 256) })
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct TransportObserverTests {
  static let previewTable: [(limit: Int?, bodyCount: Int, previewCount: Int?)] = [
    (nil, 8, nil),
    (0, 8, nil),
    (-1, 8, nil),
    (1, 5, 1),
    (4, 0, 0),
    (4, 3, 3),
    (4, 4, 4),
    (4, 5, 4),
  ]

  @Test("An observer is Sendable, as an existential too")
  func observerIsSendable() {
    requireSendable(Recorder.self)
    requireSendable(Silent.self)
    requireSendable((any TransportObserver).self)
  }

  @Test("An observer that implements nothing compiles, ignores every event, and wants no body")
  func defaultsIgnoreEverything() {
    let observer: any TransportObserver = Silent()
    observer.willSend(request(attempt: 1))
    observer.didReceive(response(attempt: 1))
    observer.didFail(failure(attempt: 1))
    observer.didFinishBody(bodyEnd(bytes: 3))
    #expect(observer.bodyPreviewLimit == nil)
    #expect(observer.bodyPreview(of: body(count: 8)) == nil)
  }

  @Test("Filtering is the observer's job: one that keeps only failures implements only that one")
  func failureOnlyObserverSeesOnlyFailures() {
    let observer = FailureOnly()
    observer.willSend(request(attempt: 1))
    observer.didReceive(response(attempt: 1))
    observer.didFail(failure(attempt: 2))
    observer.didFinishBody(bodyEnd(bytes: 3))
    #expect(observer.entries == ["fail:2"])
  }

  @Test("One that keeps only body ends implements only that one")
  func bodyOnlyObserverSeesOnlyBodyEnds() {
    let observer = BodyOnly()
    observer.willSend(request(attempt: 1))
    observer.didReceive(response(attempt: 1))
    observer.didFinishBody(bodyEnd(bytes: 3))
    #expect(observer.entries == ["body:3"])
  }

  @Test("An observer that implements everything receives every attempt in order")
  func fullObserverReceivesEveryEvent() {
    let observer = Recorder()
    observer.willSend(request(attempt: 1))
    observer.didFail(failure(attempt: 1))
    observer.willSend(request(attempt: 2))
    observer.didReceive(response(attempt: 2))
    observer.didFinishBody(bodyEnd(bytes: 3))
    #expect(observer.entries == ["send:1", "fail:1", "send:2", "receive:2", "body:3"])
  }

  @Test("The preview cap is one rule at every boundary", arguments: previewTable)
  func previewHonoursTheCap(limit: Int?, bodyCount: Int, previewCount: Int?) {
    let source = body(count: bodyCount)
    let preview = Recorder(bodyPreviewLimit: limit).bodyPreview(of: source)
    #expect(preview?.count == previewCount)
    #expect(preview == previewCount.map { Data(source.prefix($0)) })
  }

  @Test("A preview keeps the body's leading bytes verbatim")
  func previewKeepsLeadingBytes() {
    let source = Data("not-a-secret-and-then-some".utf8)
    let preview = Recorder(bodyPreviewLimit: 12).bodyPreview(of: source)
    #expect(preview.map { String(decoding: $0, as: UTF8.self) } == "not-a-secret")
  }

  @Test("Events reach an observer from a task other than the one that built them")
  @MainActor
  func eventsCrossIsolationBoundaries() async {
    let observer = Recorder()
    let sent = request(attempt: 1)
    let received = response(attempt: 1)
    await Task.detached {
      observer.willSend(sent)
      observer.didReceive(received)
    }.value
    #expect(observer.entries == ["send:1", "receive:1"])
  }

  @Test("One observer serves concurrent requests without losing an event")
  func concurrentAttemptsAreAllRecorded() async {
    let observer = Recorder()
    await withTaskGroup(of: Void.self) { group in
      for attempt in 1...8 {
        group.addTask { observer.willSend(request(attempt: attempt)) }
      }
    }
    #expect(Set(observer.entries) == Set((1...8).map { "send:\($0)" }))
  }
}
