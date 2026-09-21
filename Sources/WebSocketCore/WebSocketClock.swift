/// Erases clock identity while retaining one origin and absolute deadlines.
struct WebSocketClock: Clock {
  struct Instant: InstantProtocol {
    let offset: Swift.Duration

    func advanced(by duration: Swift.Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    func duration(to other: Instant) -> Swift.Duration {
      other.offset - offset
    }

    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  typealias Duration = Swift.Duration

  private let reading: @Sendable () -> Instant
  private let resolution: Duration
  private let sleepUntil: @Sendable (Instant, Duration?) async throws -> Void

  init<C: Clock>(_ clock: C) where C.Duration == Duration {
    let origin = clock.now
    reading = { Instant(offset: origin.duration(to: clock.now)) }
    resolution = clock.minimumResolution
    sleepUntil = { instant, tolerance in
      try await clock.sleep(until: origin.advanced(by: instant.offset), tolerance: tolerance)
    }
  }

  var minimumResolution: Duration { resolution }
  var now: Instant { reading() }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    try await sleepUntil(deadline, tolerance)
  }
}
