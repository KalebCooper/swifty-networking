import HTTPTesting

/// Records timer cleanup so backend fixtures can await cancellation without polling.
package struct WebSocketCompletionClock: Clock {
  package typealias Duration = Swift.Duration
  package typealias Instant = RecordingClock.Instant

  package let completed = WebSocketRendezvous()
  package let underlying = RecordingClock()

  package init() {}

  package var minimumResolution: Duration { .zero }
  package var now: Instant { underlying.now }

  package func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    defer { completed.arrive() }
    try await underlying.sleep(until: deadline, tolerance: tolerance)
  }
}
