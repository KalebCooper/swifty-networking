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

/// A client over `MockTransport`, defaulted apart from the arguments given here.
private func makeClient(
  authentication: Authentication? = nil,
  clock: RecordingClock,
  retryPolicy: RetryPolicy,
  timeout: Duration? = nil,
  transport: any Transport
) -> HTTPClient {
  HTTPClient(
    authentication: authentication,
    baseURL: URL.fixture("https://api.example.com"),
    clock: clock,
    retryPolicy: retryPolicy,
    timeout: timeout,
    transport: transport
  )
}

/// A `503` carrying the given `Retry-After` value.
private func unavailable(retryAfter: String) -> Response {
  .empty(headers: [.retryAfter: retryAfter], status: .serviceUnavailable)
}

/// A policy that retries a `503` up to `maxAttempts` times on the given schedule.
private func retrying503(
  _ backoff: BackoffSchedule = BackoffSchedule(delays: [first]), maxAttempts: Int = 2
) -> RetryPolicy {
  RetryPolicy(backoff: backoff, maxAttempts: maxAttempts) { $0.failure.statusCode == 503 }
}

/// Whether the failure is ``TransportError/cancelled``.
private func isCancelled(_ error: TransportError?) -> Bool {
  if case .some(.cancelled) = error { true } else { false }
}

/// The kind of a transport failure.
private func transportKind(_ error: TransportError?) -> TransportFailureKind? {
  if case .some(.transport(kind: let kind, underlying: _)) = error { kind } else { nil }
}

private let connectivity = TransportError.transport(kind: .connectivity, underlying: nil)
private let timeout = TransportError.transport(kind: .timedOut, underlying: nil)

private let first = Duration.milliseconds(10)
private let second = Duration.milliseconds(50)
private let third = Duration.milliseconds(250)

private let path = "/things"
private let request = Request(path: path)

@Suite("HTTPClient retry loop", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientRetryTests {
  @Test("a request retried twice waits the schedule's first two delays and then succeeds")
  func retriesUntilSuccess() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .failure(timeout), .failure(timeout), .success(.empty(status: .ok)),
    ])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(
        backoff: BackoffSchedule(delays: [first, second, third]), maxAttempts: 3),
      transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(2, of: clock)
    try await call.value

    #expect(clock.sleeps == [first, second])
    #expect(transport.requests.count == 3)
  }

  @Test("a policy of one attempt sends once, waits not at all, and throws what that attempt threw")
  func singleAttemptNeverWaits() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [.failure(timeout)])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first]), maxAttempts: 1),
      transport: transport)

    let error = await failure { try await client.executeExpectingNoContent(request) }

    #expect(error?.isTimeout == true)
    #expect(clock.sleeps == [])
    #expect(transport.requests.count == 1)
  }

  @Test("a request that exhausts its attempts throws the last failure and waited once less")
  func exhaustionThrowsTheLastFailure() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .failure(timeout), .failure(timeout), .failure(connectivity),
    ])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first, second]), maxAttempts: 3),
      transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(2, of: clock)
    let error = await failure { try await call.value }

    #expect(transportKind(error) == .connectivity)
    #expect(clock.sleeps == [first, second])
    #expect(transport.requests.count == 3)
  }

  @Test("a failure the predicate declines is sent once and never waited on")
  func nonRetryableFailureIsNotRetried() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [.failure(connectivity)])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first, second]), maxAttempts: 3),
      transport: transport)

    let error = await failure { try await client.executeExpectingNoContent(request) }

    #expect(transportKind(error) == .connectivity)
    #expect(clock.sleeps == [])
    #expect(transport.requests.count == 1)
  }

  @Test("a status failure reaches the predicate, so a caller can retry a 503")
  func statusFailureReachesThePredicate() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .success(.empty(status: .serviceUnavailable)), .success(.empty(status: .serviceUnavailable)),
      .success(.empty(status: .ok)),
    ])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(
        backoff: BackoffSchedule(delays: [first, second]),
        maxAttempts: 3,
        retryable: { $0.failure.statusCode == 503 }),
      transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(2, of: clock)
    try await call.value

    #expect(clock.sleeps == [first, second])
    #expect(transport.requests.count == 3)
  }

  @Test("a status the predicate declines is thrown from the first attempt")
  func declinedStatusIsNotRetried() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [.success(.empty(status: .internalServerError))])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(
        backoff: BackoffSchedule(delays: [first]),
        maxAttempts: 3,
        retryable: { $0.failure.statusCode == 503 }),
      transport: transport)

    let error = await failure { try await client.executeExpectingNoContent(request) }

    #expect(error?.statusCode == 500)
    #expect(clock.sleeps == [])
    #expect(transport.requests.count == 1)
  }

  @Test("a schedule that never waits still records the wait it was asked for, and suspends nobody")
  func zeroScheduleRecordsZeroWaits() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .failure(timeout), .failure(timeout), .success(.empty(status: .ok)),
    ])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: .zero, maxAttempts: 3),
      transport: transport)

    try await client.executeExpectingNoContent(request)

    #expect(clock.sleeps == [.zero, .zero])
    #expect(clock.pendingSleeps == 0)
    #expect(transport.requests.count == 3)
  }

  @Test("attempts past the end of the table repeat its last delay")
  func scheduleSaturatesPastItsTable() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .failure(timeout), .failure(timeout), .failure(timeout), .success(.empty(status: .ok)),
    ])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first, second]), maxAttempts: 4),
      transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(3, of: clock)
    try await call.value

    #expect(clock.sleeps == [first, second, second])
    #expect(transport.requests.count == 4)
  }

  @Test("a request's own policy retries where the client's would not")
  func requestPolicyOverridesTheClientPolicy() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [.failure(timeout), .success(.empty(status: .ok))])
    let client = makeClient(clock: clock, retryPolicy: .disabled, transport: transport)
    let retried = Request(
      options: RequestOptions(
        retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first]), maxAttempts: 2)),
      path: path)

    let call = Task { try await client.executeExpectingNoContent(retried) }
    await answerWaits(1, of: clock)
    try await call.value

    #expect(clock.sleeps == [first])
    #expect(transport.requests.count == 2)
  }

  @Test("a 503 with Retry-After 2 waits two seconds instead of the table delay")
  func retryAfterReplacesTheTableDelay() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .success(unavailable(retryAfter: "2")), .success(.empty(status: .ok)),
    ])
    let client = makeClient(clock: clock, retryPolicy: retrying503(), transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(1, of: clock)
    try await call.value

    #expect(clock.sleeps == [.seconds(2)])
    #expect(transport.requests.count == 2)
  }

  @Test("a Retry-After in HTTP-date form is ignored and the table delay is used")
  func retryAfterDateIsIgnored() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .success(unavailable(retryAfter: "Wed, 21 Oct 2015 07:28:00 GMT")),
      .success(.empty(status: .ok)),
    ])
    let client = makeClient(clock: clock, retryPolicy: retrying503(), transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(1, of: clock)
    try await call.value

    #expect(clock.sleeps == [first])
    #expect(transport.requests.count == 2)
  }

  @Test("a Retry-After that is not a number is ignored")
  func retryAfterNonNumberIsIgnored() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .success(unavailable(retryAfter: "soon")), .success(.empty(status: .ok)),
    ])
    let client = makeClient(clock: clock, retryPolicy: retrying503(), transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(1, of: clock)
    try await call.value

    #expect(clock.sleeps == [first])
    #expect(transport.requests.count == 2)
  }

  @Test("a Retry-After of zero is waited as zero, so the retry goes out at once")
  func retryAfterZeroRetriesAtOnce() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .success(unavailable(retryAfter: "0")), .success(.empty(status: .ok)),
    ])
    let client = makeClient(clock: clock, retryPolicy: retrying503(), transport: transport)

    try await client.executeExpectingNoContent(request)

    #expect(clock.sleeps == [.zero])
    #expect(clock.pendingSleeps == 0)
    #expect(transport.requests.count == 2)
  }

  @Test("the server's Retry-After is waited as written, with the schedule's jitter left out")
  func retryAfterIsNotJittered() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .success(unavailable(retryAfter: "2")), .success(unavailable(retryAfter: "soon")),
      .success(.empty(status: .ok)),
    ])
    let doubling = BackoffSchedule(delays: [first]) { $0 * 2 }
    let client = makeClient(
      clock: clock, retryPolicy: retrying503(doubling, maxAttempts: 3), transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(2, of: clock)
    try await call.value

    #expect(clock.sleeps == [.seconds(2), first * 2])
    #expect(transport.requests.count == 3)
  }

  @Test("a Retry-After on a redirect the policy stopped at is honoured like any other")
  func retryAfterOnAStoppedRedirect() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .success(.empty(headers: [.location: "/elsewhere", .retryAfter: "3"], status: .found)),
      .success(.empty(status: .ok)),
    ])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first]), maxAttempts: 2) {
        $0.failure.statusCode == 302
      },
      transport: transport)
    let unfollowed = Request(options: RequestOptions(redirectPolicy: .never), path: path)

    let call = Task { try await client.executeExpectingNoContent(unfollowed) }
    await answerWaits(1, of: clock)
    try await call.value

    #expect(clock.sleeps == [.seconds(3)])
    #expect(transport.requests.map(\.request.path) == [path, path])
  }

  @Test("a Retry-After wait is time the request spent, so the next failure's elapsed covers it")
  func retryAfterWaitAccruesInElapsed() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .success(unavailable(retryAfter: "2")), .failure(timeout), .success(.empty(status: .ok)),
    ])
    let seen = Mutex<[Duration]>([])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first]), maxAttempts: 3) {
        failed in
        seen.withLock { $0.append(failed.elapsed) }
        return failed.failure.statusCode == 503 || failed.failure.isTimeout
      },
      transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(2, of: clock)
    try await call.value

    #expect(seen.withLock { $0 } == [.zero, .seconds(2)])
    #expect(clock.sleeps == [.seconds(2), first])
    #expect(transport.requests.count == 3)
  }

  @Test("a Retry-After on a 401 the replay answers is not read; the attempt ends on the replay")
  func retryAfterOnAReplayedUnauthorizedIsNotRead() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .success(.empty(headers: [.retryAfter: "9"], status: .unauthorized)),
      .success(.empty(status: .serviceUnavailable)),
      .success(.empty(status: .ok)),
    ])
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens),
      clock: clock,
      retryPolicy: retrying503(),
      transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(1, of: clock)
    try await call.value

    #expect(clock.sleeps == [first])
    #expect(transport.requests.count == 3)
  }

  @Test("the predicate receives the attempt ordinal and the elapsed time on the injected clock")
  func predicateReceivesOrdinalAndElapsed() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [
      .failure(timeout), .failure(timeout), .success(.empty(status: .ok)),
    ])
    let seen = Mutex<[(attempt: Int, elapsed: Duration)]>([])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first, second]), maxAttempts: 3) {
        failed in
        seen.withLock { $0.append((failed.attempt, failed.elapsed)) }
        return true
      },
      transport: HoldingTransport(clock: clock, inner: mock))

    // Each send holds one second on the clock, then the backoff wait follows: five sleeps in all.
    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(5, of: clock)
    try await call.value

    let attempts = seen.withLock { $0.map(\.attempt) }
    let elapsed = seen.withLock { $0.map(\.elapsed) }
    #expect(attempts == [1, 2])
    #expect(elapsed == [.seconds(1), .seconds(2) + first])
    #expect(clock.sleeps == [.seconds(1), first, .seconds(1), second, .seconds(1)])
  }

  @Test("a predicate that budgets elapsed time stops retrying once the budget is spent")
  func budgetedPredicateStops() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .failure(timeout), .failure(timeout), .failure(timeout), .success(.empty(status: .ok)),
    ])
    let budget = first + second
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first, second]), maxAttempts: 5) {
        $0.elapsed < budget
      },
      transport: transport)

    // The third failure arrives with exactly the budget elapsed, so it is the one thrown.
    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(2, of: clock)
    let error = await failure { try await call.value }

    #expect(error?.isTimeout == true)
    #expect(clock.sleeps == [first, second])
    #expect(transport.requests.count == 3)
  }

  @Test("a Retry-After longer than the remaining deadline is cut short and the request times out")
  func retryAfterPastTheDeadline() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .success(unavailable(retryAfter: "5")), .success(.empty(status: .ok)),
    ])
    let client = makeClient(
      clock: clock, retryPolicy: retrying503(), timeout: .seconds(1), transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await clock.waitForPendingSleep(count: 2)
    clock.advance(by: .seconds(1))
    let error = await failure { try await call.value }

    #expect(transportKind(error) == .timedOut)
    #expect(clock.sleeps.sorted() == [.seconds(1), .seconds(5)])
    #expect(transport.requests.count == 1)
  }

  @Test("a request's own policy stops the retrying the client would have done")
  func requestPolicyDisablesTheClientPolicy() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [.failure(timeout), .success(.empty(status: .ok))])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first]), maxAttempts: 3),
      transport: transport)
    let once = Request(options: RequestOptions(retryPolicy: .disabled), path: path)

    let error = await failure { try await client.executeExpectingNoContent(once) }

    #expect(error?.isTimeout == true)
    #expect(clock.sleeps == [])
    #expect(transport.requests.count == 1)
  }
}

@Suite("HTTPClient retry cancellation", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientRetryCancellationTests {
  @Test("a request cancelled while it waits fails as cancelled and sends nothing more")
  func cancellationDuringTheWait() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [.failure(timeout), .success(.empty(status: .ok))])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first, second]), maxAttempts: 3),
      transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await clock.waitForPendingSleep()
    call.cancel()
    let error = await failure { try await call.value }

    #expect(isCancelled(error))
    #expect(clock.sleeps == [first])
    #expect(transport.requests.count == 1)
  }

  @Test("a request already cancelled when an attempt fails is answered before it waits at all")
  func cancellationBeforeTheWait() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [.failure(timeout), .success(.empty(status: .ok))])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [first]), maxAttempts: 3),
      transport: transport)

    // Cancelling from inside the task, before its first suspension, means the attempt runs and fails
    // with the cancellation already in place when the backoff wait is reached.
    let call = Task {
      unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
      try await client.executeExpectingNoContent(request)
    }
    let error = await failure { try await call.value }

    #expect(isCancelled(error))
    #expect(clock.sleeps == [])
    #expect(transport.requests.count == 1)
  }

  @Test("a predicate that retries everything still does not retry a cancellation")
  func cancellationIsNeverRetried() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(results: [.failure(timeout), .success(.empty(status: .ok))])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(
        backoff: BackoffSchedule(delays: [first]), maxAttempts: 3, retryable: { _ in true }),
      transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await clock.waitForPendingSleep()
    call.cancel()
    let error = await failure { try await call.value }

    #expect(isCancelled(error))
    #expect(clock.sleeps == [first])
    #expect(transport.requests.count == 1)
  }
}
