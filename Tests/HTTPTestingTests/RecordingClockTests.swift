import HTTPCore
import HTTPTesting
import Synchronization
import Testing

/// Sleeps once per attempt, for the delay the schedule gives that attempt.
private func backOff<C: Clock>(attempts: Int, clock: C, schedule: BackoffSchedule) async throws
where C.Duration == Duration {
  for attempt in 1...attempts {
    try await Task.sleep(for: schedule.delay(forAttempt: attempt), tolerance: nil, clock: clock)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct RecordingClockReadingTests {
  @Test("A fresh clock reads zero, rounds nothing, has nobody sleeping, and remembers nothing")
  func freshClock() {
    let clock = RecordingClock()
    #expect(clock.now.duration(to: clock.now) == .zero)
    #expect(clock.minimumResolution == .zero)
    #expect(clock.pendingSleeps == 0)
    #expect(clock.sleeps.isEmpty)
  }

  @Test("advance(by:) moves the reading by exactly the duration given")
  func advanceMovesReading() {
    let clock = RecordingClock()
    let start = clock.now
    clock.advance(by: .seconds(5))
    #expect(start.duration(to: clock.now) == .seconds(5))
    #expect(clock.now == start.advanced(by: .seconds(5)))
    #expect(start < clock.now)
  }

  @Test("advanceAll() with nobody sleeping leaves the reading where it is")
  func advanceAllIdleIsNoOp() {
    let clock = RecordingClock()
    let start = clock.now
    clock.advanceAll()
    #expect(clock.now == start)
  }

  @Test("A deadline already reached returns without suspending, and is still recorded")
  func reachedDeadlineReturnsImmediately() async throws {
    let clock = RecordingClock()
    let start = clock.now
    try await clock.sleep(until: start, tolerance: nil)
    clock.advance(by: .seconds(1))
    try await clock.sleep(until: start, tolerance: .milliseconds(5))
    #expect(clock.sleeps == [.zero, .seconds(-1)])
    #expect(clock.pendingSleeps == 0)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct RecordingClockSleepTests {
  @Test("Sleeps are recorded in call order as the durations that were asked for")
  func sleepsRecordedInOrder() async throws {
    let clock = RecordingClock()
    let work = Task {
      try await Task.sleep(for: .seconds(1), clock: clock)
      try await Task.sleep(for: .milliseconds(250), tolerance: .milliseconds(10), clock: clock)
      try await clock.sleep(for: .seconds(3))
    }
    await clock.waitForPendingSleep()
    #expect(clock.sleeps == [.seconds(1)])
    #expect(clock.pendingSleeps == 1)
    clock.advance(by: .seconds(1))
    await clock.waitForPendingSleep()
    clock.advance(by: .milliseconds(250))
    await clock.waitForPendingSleep()
    clock.advance(by: .seconds(3))
    try await work.value

    #expect(clock.sleeps == [.seconds(1), .milliseconds(250), .seconds(3)])
    #expect(clock.pendingSleeps == 0)
  }

  @Test("advance(by:) resumes only the sleepers whose deadline it reaches")
  func advanceResumesOnlyDue() async throws {
    let clock = RecordingClock()
    let short = Task { try await Task.sleep(for: .seconds(1), clock: clock) }
    let long = Task { try await Task.sleep(for: .seconds(3), clock: clock) }
    await clock.waitForPendingSleep(count: 2)

    clock.advance(by: .seconds(2))
    try await short.value
    #expect(clock.pendingSleeps == 1)

    clock.advance(by: .seconds(1))
    try await long.value
    #expect(clock.pendingSleeps == 0)
  }

  @Test(
    "Sleepers with mixed deadlines resume as each deadline is reached, whatever order they came in")
  func advanceResumesByDeadlineNotRegistration() async throws {
    let clock = RecordingClock()
    let start = clock.now
    let deadlines = [3, 1, 2, 2].map { start.advanced(by: .seconds($0)) }
    let sleepers = deadlines.map { deadline in
      Task { try await clock.sleep(until: deadline, tolerance: nil) }
    }
    await clock.waitForPendingSleep(count: 4)

    clock.advance(by: .seconds(1))
    try await sleepers[1].value
    #expect(clock.pendingSleeps == 3)

    clock.advance(by: .seconds(1))
    try await sleepers[2].value
    try await sleepers[3].value
    #expect(clock.pendingSleeps == 1)

    clock.advance(by: .seconds(1))
    try await sleepers[0].value
    #expect(clock.pendingSleeps == 0)
    #expect(clock.now == deadlines[0])
  }

  @Test("waitForPendingSleep(count:) releases once that many are parked; advanceAll drains")
  func waitThenAdvanceAcrossGroup() async throws {
    let clock = RecordingClock()
    let start = clock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
      for seconds in 1...3 {
        group.addTask { try await Task.sleep(for: .seconds(seconds), clock: clock) }
      }
      await clock.waitForPendingSleep(count: 3)
      #expect(clock.pendingSleeps == 3)

      clock.advance(by: .seconds(2))
      #expect(clock.pendingSleeps == 1)

      clock.advanceAll()
      #expect(clock.pendingSleeps == 0)
      try await group.waitForAll()
    }
    #expect(clock.sleeps.sorted() == [.seconds(1), .seconds(2), .seconds(3)])
    #expect(start.duration(to: clock.now) == .seconds(3))
  }

  @Test("waitForPendingSleep returns at once when enough sleepers are already parked")
  func waitReturnsImmediatelyWhenSatisfied() async throws {
    let clock = RecordingClock()
    let work = Task { try await Task.sleep(for: .seconds(1), clock: clock) }
    await clock.waitForPendingSleep()
    await clock.waitForPendingSleep()
    await clock.waitForPendingSleep(count: 0)
    clock.advanceAll()
    try await work.value
  }

  @Test("A retry loop written against any Clock records the schedule's delay per failed attempt")
  func genericConsumerRecordsSchedule() async throws {
    let clock = RecordingClock()
    let schedule = BackoffSchedule(
      delays: [.milliseconds(100), .milliseconds(200), .milliseconds(400)])
    let work = Task { try await backOff(attempts: 4, clock: clock, schedule: schedule) }
    for _ in 1...4 {
      await clock.waitForPendingSleep()
      clock.advanceAll()
    }
    try await work.value

    #expect(
      clock.sleeps == [
        .milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(400),
      ])
    #expect(clock.pendingSleeps == 0)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct RecordingClockCancellationTests {
  @Test(
    "Cancelling a parked sleeper throws, drops it, and a later advanceAll has nothing to resume")
  func cancelWhileParked() async {
    let clock = RecordingClock()
    let start = clock.now
    let work = Task { try await Task.sleep(for: .seconds(1), clock: clock) }
    await clock.waitForPendingSleep()
    #expect(clock.pendingSleeps == 1)

    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
    #expect(clock.pendingSleeps == 0)

    // A checked continuation traps on a second resume, so this is safe only with an empty registry.
    clock.advanceAll()
    #expect(clock.now == start)
    #expect(clock.sleeps == [.seconds(1)])
  }

  @Test("A task cancelled before it sleeps never registers, but the request is recorded")
  func cancelBeforeSleep() async {
    let clock = RecordingClock()
    let work = Task {
      unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
      try await clock.sleep(until: clock.now.advanced(by: .seconds(1)), tolerance: nil)
    }
    await #expect(throws: CancellationError.self) { try await work.value }
    #expect(clock.pendingSleeps == 0)
    #expect(clock.sleeps == [.seconds(1)])
  }

  @Test("Cancellation racing the registration resolves the same way whichever side wins")
  func cancelRacingRegistration() async {
    for _ in 0..<16 {
      let clock = RecordingClock()
      let work = Task { try await Task.sleep(for: .seconds(1), clock: clock) }
      work.cancel()
      await #expect(throws: CancellationError.self) { try await work.value }
      #expect(clock.pendingSleeps == 0)
      clock.advanceAll()
    }
  }

  @Test("Cancelling one parked sleeper leaves the others parked and resumable")
  func cancelOneOfMany() async throws {
    let clock = RecordingClock()
    let doomed = Task { try await Task.sleep(for: .seconds(1), clock: clock) }
    let survivor = Task { try await Task.sleep(for: .seconds(1), clock: clock) }
    await clock.waitForPendingSleep(count: 2)

    doomed.cancel()
    await #expect(throws: CancellationError.self) { try await doomed.value }
    #expect(clock.pendingSleeps == 1)

    clock.advance(by: .seconds(1))
    try await survivor.value
    #expect(clock.pendingSleeps == 0)
  }

  @Test("A waiter cancelled before or while waiting returns instead of hanging")
  func cancelledWaiterReturns() async {
    let clock = RecordingClock()
    let cancelledFirst = Task {
      unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
      await clock.waitForPendingSleep()
      return clock.pendingSleeps
    }
    #expect(await cancelledFirst.value == 0)

    let parked = Task { await clock.waitForPendingSleep(count: 5) }
    parked.cancel()
    await parked.value
    #expect(clock.pendingSleeps == 0)
  }
}
