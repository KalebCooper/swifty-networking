import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

private let correlationID = "8b1f"
private let url = URL.fixture("https://example.com/a")

/// An error the tests pass as an underlying error.
private struct ProbeError: Error {}

private func requestEvent(attempt: Int) -> RequestEvent {
  RequestEvent(
    attempt: attempt, authAttached: true, correlationID: correlationID, method: .get, url: url)
}

private func responseEvent(attempt: Int) -> ResponseEvent {
  ResponseEvent(
    attempt: attempt, authAttached: true, correlationID: correlationID, duration: .milliseconds(10),
    method: .get, status: .ok, url: url)
}

private func failureEvent(attempt: Int) -> FailureEvent {
  FailureEvent(
    attempt: attempt, authAttached: true, correlationID: correlationID, duration: .milliseconds(10),
    failure: .transport(kind: .timedOut, underlying: ProbeError()), method: .get, url: url)
}

/// A body of `count` bytes, each byte its own index modulo 256.
private func body(count: Int) -> Data {
  Data((0..<count).map { UInt8($0 % 256) })
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct RecordingObserverTests {
  @Test("Events are captured in the order they were reported, across all four kinds")
  func eventsCapturedInCallOrder() {
    let observer = RecordingObserver()
    observer.willSend(requestEvent(attempt: 1))
    observer.didReceive(responseEvent(attempt: 1))
    observer.willSend(requestEvent(attempt: 2))
    observer.didFail(failureEvent(attempt: 2))
    observer.didFinishBody(BodyEvent(bytesReceived: 12, correlationID: correlationID))

    let events = observer.events
    #expect(events.count == 5)

    guard case .sent(let first) = events[0] else {
      Issue.record("expected .sent at index 0")
      return
    }
    #expect(first.attempt == 1)

    guard case .received(let second) = events[1] else {
      Issue.record("expected .received at index 1")
      return
    }
    #expect(second.attempt == 1)

    guard case .sent(let third) = events[2] else {
      Issue.record("expected .sent at index 2")
      return
    }
    #expect(third.attempt == 2)

    guard case .failed(let fourth) = events[3] else {
      Issue.record("expected .failed at index 3")
      return
    }
    #expect(fourth.attempt == 2)

    guard case .finishedBody(let fifth) = events[4] else {
      Issue.record("expected .finishedBody at index 4")
      return
    }
    #expect(fifth.bytesReceived == 12)
    #expect(fifth.failure == nil)
  }

  @Test("last is nil before any event and the newest one after each")
  func lastTracksTheNewestEvent() {
    let observer = RecordingObserver()
    #expect(observer.last == nil)

    observer.willSend(requestEvent(attempt: 1))
    guard case .sent = observer.last else {
      Issue.record("expected .sent after willSend")
      return
    }

    observer.didReceive(responseEvent(attempt: 1))
    guard case .received = observer.last else {
      Issue.record("expected .received after didReceive")
      return
    }

    observer.didFail(failureEvent(attempt: 2))
    guard case .failed = observer.last else {
      Issue.record("expected .failed after didFail")
      return
    }
  }

  @Test("reset() empties the event log")
  func resetEmptiesTheLog() {
    let observer = RecordingObserver()
    observer.willSend(requestEvent(attempt: 1))
    observer.didReceive(responseEvent(attempt: 1))

    observer.reset()

    #expect(observer.events.isEmpty)
    #expect(observer.last == nil)
  }

  @Test(
    "bodyPreviewLimit round-trips through the protocol requirement, and drives the cap",
    arguments: [
      (limit: Int?.none, bodyCount: 8, previewCount: Int?.none),
      (limit: 4, bodyCount: 8, previewCount: 4),
    ] as [(limit: Int?, bodyCount: Int, previewCount: Int?)]
  )
  func bodyPreviewLimitRoundTrips(limit: Int?, bodyCount: Int, previewCount: Int?) {
    let observer = RecordingObserver(bodyPreviewLimit: limit)
    #expect(observer.bodyPreviewLimit == limit)

    let preview = observer.bodyPreview(of: body(count: bodyCount))
    #expect(preview?.count == previewCount)
  }

  @Test("An 8-way burst records exactly one event per task")
  func concurrentBurstRecordsEveryEvent() async {
    let observer = RecordingObserver()
    await withTaskGroup(of: Void.self) { group in
      for attempt in 1...8 {
        group.addTask { observer.willSend(requestEvent(attempt: attempt)) }
      }
    }
    #expect(observer.events.count == 8)
  }

  @Test("Callable from a nonisolated context")
  func callableFromNonisolatedContext() {
    let observer = RecordingObserver()
    observer.willSend(requestEvent(attempt: 1))
    #expect(observer.events.count == 1)
  }

  @Test("Callable from the main actor")
  @MainActor
  func callableFromMainActor() {
    let observer = RecordingObserver()
    observer.willSend(requestEvent(attempt: 1))
    #expect(observer.events.count == 1)
  }

  @Test("Existential any TransportObserver dispatch reaches the recorder")
  func existentialDispatchReachesTheRecorder() {
    let recorder = RecordingObserver()
    let observer: any TransportObserver = recorder

    observer.willSend(requestEvent(attempt: 1))
    observer.didReceive(responseEvent(attempt: 1))
    observer.didFail(failureEvent(attempt: 2))

    #expect(recorder.events.count == 3)
  }
}
