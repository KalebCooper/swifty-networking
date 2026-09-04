import HTTPCore
import HTTPTesting
import Synchronization
import Testing

/// Compile-time check that a type is `Sendable`.
private func requireSendable<T: Sendable>(_: T.Type) {}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct BackoffScheduleTests {
  static let table = BackoffSchedule(
    delays: [.milliseconds(100), .milliseconds(250), .seconds(1)]
  )

  static let delayTable: [(attempt: Int, expected: Duration)] = [
    (Int.min, .milliseconds(100)),
    (-1, .milliseconds(100)),
    (0, .milliseconds(100)),
    (1, .milliseconds(100)),
    (2, .milliseconds(250)),
    (3, .seconds(1)),
    (4, .seconds(1)),
    (99, .seconds(1)),
    (Int.max, .seconds(1)),
  ]

  @Test(
    "Each attempt reads its own entry and both ends of the table saturate", arguments: delayTable)
  func delayMatchesTable(attempt: Int, expected: Duration) {
    #expect(Self.table.delay(forAttempt: attempt) == expected)
  }

  @Test("An empty table never waits", arguments: [Int.min, -1, 0, 1, 2, 400, Int.max])
  func emptyTableNeverWaits(attempt: Int) {
    #expect(BackoffSchedule.zero.delay(forAttempt: attempt) == .zero)
    #expect(BackoffSchedule(delays: []).delay(forAttempt: attempt) == .zero)
  }

  @Test("A single-entry table is a constant delay", arguments: [1, 2, 30])
  func singleEntryTableIsConstant(attempt: Int) {
    let schedule = BackoffSchedule(delays: [.milliseconds(20)])
    #expect(schedule.delay(forAttempt: attempt) == .milliseconds(20))
  }

  @Test("Jitter transforms the entry the table yields, once per delay, past its end as well")
  func jitterTransformsTheTableValue() {
    let seen = Mutex<[Duration]>([])
    let schedule = BackoffSchedule(delays: [.seconds(1), .seconds(2)]) { delay in
      seen.withLock { $0.append(delay) }
      return delay * 2
    }

    #expect(schedule.delay(forAttempt: 1) == .seconds(2))
    #expect(schedule.delay(forAttempt: 2) == .seconds(4))
    #expect(schedule.delay(forAttempt: 7) == .seconds(4))
    #expect(seen.withLock { $0 } == [.seconds(1), .seconds(2), .seconds(2)])
  }

  @Test("The default jitter leaves the written delays untouched")
  func defaultJitterIsIdentity() {
    let written: [Duration] = [.milliseconds(100), .milliseconds(250), .seconds(1)]
    #expect((1...3).map(Self.table.delay(forAttempt:)) == written)
  }

  @Test("A schedule crosses isolation boundaries freely")
  func scheduleIsSendable() {
    requireSendable(BackoffSchedule.self)
  }
}
