import Synchronization

/// A `Clock` whose reading moves only when a test moves it, and which records every sleep it was
/// asked for.
///
/// Inject one wherever the code under test takes a `Clock`, then drive time from the outside. A
/// sleeper stays parked until ``advance(by:)`` or ``advanceAll()`` carries the reading past its
/// deadline, and ``sleeps`` holds the duration of every request in call order, so a backoff schedule
/// is asserted as values instead of measured against wall time. A `tolerance` is accepted and
/// ignored, and a sleeper resumes at exactly the deadline it asked for.
///
/// ## Awaiting a Sleeper, Then Advancing
///
/// A sleeper registers on its own task, so advancing the clock right after that task is spawned
/// races the registration. ``waitForPendingSleep(count:)`` returns once that many sleepers are
/// parked, which makes the sequence deterministic:
///
/// ```swift
/// @Test func waitsTheBackoffDelayBetweenAttempts() async throws {
///   let clock = RecordingClock()
///   let transport = MockTransport(results: [
///     .failure(.transport(kind: .timedOut, underlying: nil)),
///     .success(.ok(json: Fixtures.jsonObject(["id": "42"]))),
///   ])
///   let client = HTTPClient(
///     baseURL: URL(string: "https://api.example.com")!,
///     clock: clock,
///     retryPolicy: RetryPolicy(
///       backoff: BackoffSchedule(delays: [.milliseconds(10)]),
///       maxAttempts: 2
///     ),
///     transport: transport
///   )
///
///   let inFlight = Task { try await client.execute(Request(path: "/me")) }
///   await clock.waitForPendingSleep()
///   clock.advanceAll()
///
///   _ = try await inFlight.value
///   #expect(clock.sleeps == [.milliseconds(10)])
/// }
/// ```
///
/// ## Cancellation
///
/// A sleeper's task can be cancelled before the sleep registers, while it is parked, or in the same
/// moment the clock advances past its deadline. In every case the sleeper is resumed exactly once,
/// throwing `CancellationError` and leaving ``pendingSleeps``, so a later ``advance(by:)`` or
/// ``advanceAll()`` has nothing of its left to resume.
///
/// ## Isolation
///
/// One `Mutex` guards the reading and both registries, so the clock is safe to drive from one task
/// while others sleep on it. It is not an `actor`, so ``now``, ``sleeps``, and ``pendingSleeps``
/// read synchronously.
public final class RecordingClock: Clock, Sendable {
  /// A point on a ``RecordingClock``'s timeline, measured from the clock's creation.
  ///
  /// The clock mints its own instants: a system clock's instant can be read but not constructed,
  /// and a deterministic clock places deadlines at values the test chose.
  public struct Instant: InstantProtocol {
    /// Time elapsed on the owning clock between its creation and this instant.
    let offset: Swift.Duration

    /// Returns the instant `duration` later than this one on the same clock.
    ///
    /// - Parameter duration: How much later the returned instant lies.
    /// - Returns: The later instant.
    public func advanced(by duration: Swift.Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    /// Returns the time between this instant and `other`, negative when `other` is earlier.
    ///
    /// - Parameter other: The instant to measure to.
    /// - Returns: The signed distance between the two instants.
    public func duration(to other: Instant) -> Swift.Duration {
      other.offset - offset
    }

    /// Orders instants by their position on the timeline.
    ///
    /// - Parameters:
    ///   - lhs: The first instant.
    ///   - rhs: The second instant.
    /// - Returns: `true` when `lhs` lies earlier than `rhs`.
    public static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.offset < rhs.offset
    }
  }

  /// The unit this clock measures in: the standard library's `Duration`, so a schedule written
  /// against a production clock reads unchanged against this one.
  public typealias Duration = Swift.Duration

  /// A parked `sleep(until:tolerance:)` call.
  ///
  /// The `id` ties a task's cancellation handler back to its entry, and `sequence` breaks ties
  /// between equal deadlines so resumption order matches registration order.
  private struct Sleeper {
    let continuation: CheckedContinuation<Void, any Error>
    let deadline: Instant
    let id: Int
    let sequence: Int
  }

  /// A parked `waitForPendingSleep(count:)` call, released once `pendingSleeps` reaches
  /// `threshold`.
  private struct Waiter {
    let continuation: CheckedContinuation<Void, Never>
    let id: Int
    let threshold: Int
  }

  private struct State {
    var elapsed: Swift.Duration = .zero
    var nextID = 0
    var sleepers: [Sleeper] = []
    var sleeps: [Swift.Duration] = []
    var waiters: [Waiter] = []

    mutating func claimID() -> Int {
      nextID += 1
      return nextID
    }

    /// Removes every sleeper whose deadline the reading has reached, in the order they resume.
    mutating func takeDueSleepers() -> [Sleeper] {
      let now = Instant(offset: elapsed)
      let due = sleepers.filter { $0.deadline <= now }
      sleepers.removeAll { $0.deadline <= now }
      return due.sorted { ($0.deadline, $0.sequence) < ($1.deadline, $1.sequence) }
    }

    /// Removes every waiter whose threshold the registry now satisfies.
    mutating func takeSatisfiedWaiters() -> [Waiter] {
      let count = sleepers.count
      let satisfied = waiters.filter { $0.threshold <= count }
      waiters.removeAll { $0.threshold <= count }
      return satisfied
    }
  }

  private let state = Mutex(State())

  /// Creates a clock reading zero, with nothing recorded and nobody sleeping.
  public init() {}

  /// Zero: this clock rounds no deadline, so a sleeper resumes at exactly the instant it asked for.
  public var minimumResolution: Swift.Duration { .zero }

  /// The current reading, which changes only through ``advance(by:)`` and ``advanceAll()``.
  public var now: Instant {
    Instant(offset: state.withLock { $0.elapsed })
  }

  /// How many sleepers are parked right now: registered, and resumed neither by the clock nor by
  /// cancellation.
  public var pendingSleeps: Int {
    state.withLock { $0.sleepers.count }
  }

  /// The duration of every sleep requested so far, in call order.
  ///
  /// Each entry is the deadline's distance from the reading at the moment of the call, so
  /// `Task.sleep(for:tolerance:clock:)` records exactly the duration it was given. A request is
  /// recorded whether or not it ever suspends: a deadline the reading has already passed records a
  /// zero or negative entry, and a sleep refused because its task was already cancelled records
  /// what it asked for.
  public var sleeps: [Swift.Duration] {
    state.withLock { $0.sleeps }
  }

  /// Moves the reading forward by `duration` and resumes every sleeper whose deadline it reaches.
  ///
  /// Sleepers with later deadlines stay parked. Continuations resume in deadline order, and equal
  /// deadlines in registration order, but which resumed task runs first afterwards is the
  /// executor's decision. Advance one deadline at a time when a test needs one sleeper to finish
  /// before another.
  ///
  /// - Parameter duration: How far forward to move the reading.
  public func advance(by duration: Swift.Duration) {
    let due = state.withLock { state in
      state.elapsed += duration
      return state.takeDueSleepers()
    }
    for sleeper in due {
      sleeper.continuation.resume()
    }
  }

  /// Moves the reading to the furthest pending deadline and resumes every sleeper, in the order
  /// ``advance(by:)`` uses.
  ///
  /// With nobody sleeping, the reading does not move.
  public func advanceAll() {
    let due = state.withLock { state in
      if let furthest = state.sleepers.map(\.deadline.offset).max(), furthest > state.elapsed {
        state.elapsed = furthest
      }
      return state.takeDueSleepers()
    }
    for sleeper in due {
      sleeper.continuation.resume()
    }
  }

  /// Records the request, then parks the calling task until the reading reaches `deadline`.
  ///
  /// A deadline the reading has already passed returns without suspending. A task cancelled before
  /// this call, while parked, or in the same moment the clock advances past its deadline throws
  /// `CancellationError` exactly once and leaves ``pendingSleeps``.
  ///
  /// - Parameters:
  ///   - deadline: The instant to resume at.
  ///   - tolerance: Accepted and ignored; the deadline is honoured exactly.
  /// - Throws: `CancellationError` when the calling task is cancelled.
  public func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
    let id: Int = state.withLock { state in
      state.sleeps.append(deadline.offset - state.elapsed)
      return state.claimID()
    }
    try Task.checkCancellation()
    guard deadline > now else { return }

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        // The cancellation flag is read under the same lock the handler removes entries under, so a
        // cancellation that landed before this point is seen here, and one that lands after it
        // finds the entry to remove.
        let (cancelled, waiters): (Bool, [Waiter]) = state.withLock { state in
          guard !Task.isCancelled else { return (true, []) }
          let sequence = state.claimID()
          state.sleepers.append(
            Sleeper(continuation: continuation, deadline: deadline, id: id, sequence: sequence))
          return (false, state.takeSatisfiedWaiters())
        }
        if cancelled {
          continuation.resume(throwing: CancellationError())
        }
        for waiter in waiters {
          waiter.continuation.resume()
        }
      }
    } onCancel: {
      let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
        guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return state.sleepers.remove(at: index).continuation
      }
      continuation?.resume(throwing: CancellationError())
    }
  }

  /// Suspends until at least `count` sleepers are parked, returning at once when they already are.
  ///
  /// A waiter is released inside the same critical section that registers the sleeper it waited
  /// for, so nothing polls and no real time passes. If the waiting task is itself cancelled, this
  /// returns early with the condition unmet, so check ``pendingSleeps`` before trusting it in a test
  /// that can be cancelled.
  ///
  /// - Parameter count: How many parked sleepers to wait for; `1` by default.
  public func waitForPendingSleep(count: Int = 1) async {
    let id: Int = state.withLock { $0.claimID() }

    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resumeNow: Bool = state.withLock { state in
          guard state.sleepers.count < count, !Task.isCancelled else { return true }
          state.waiters.append(Waiter(continuation: continuation, id: id, threshold: count))
          return false
        }
        if resumeNow {
          continuation.resume()
        }
      }
    } onCancel: {
      let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
        guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
        return state.waiters.remove(at: index).continuation
      }
      continuation?.resume()
    }
  }
}
