import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A client over `HoldingTransport` and `RecordingClock`, defaulted apart from the arguments given
/// here.
private func makeClient(
  clock: RecordingClock,
  retryPolicy: RetryPolicy = .disabled,
  timeout: Duration? = nil,
  transport: HoldingTransport
) -> HTTPClient {
  HTTPClient(
    baseURL: URL.fixture("https://api.example.com"),
    clock: clock,
    retryPolicy: retryPolicy,
    timeout: timeout,
    transport: transport
  )
}

/// Whether the failure is the client's own deadline: a timeout carrying no system error.
private func isDeadline(_ error: TransportError?) -> Bool {
  if case .some(.transport(kind: .timedOut, underlying: nil)) = error { true } else { false }
}

/// The hold every send parks on before it reaches the mock, so a deadline shorter than this fires
/// with the send still parked and one longer than it is cancelled by the response.
private let hold = Duration.seconds(1)
private let short = Duration.milliseconds(500)
private let long = Duration.seconds(5)

private let path = "/people/1"
private let request = Request(path: path)
private let ok = Response.ok(json: Fixtures.jsonObject(["name": "Ada"]))

@Suite("HTTPClient deadline", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientDeadlineTests {
  @Test("a request past its deadline throws timedOut and the transport call is cancelled")
  func pastTheDeadlineThrowsTimedOut() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(
      clock: clock, timeout: short, transport: HoldingTransport(clock: clock, inner: mock))

    let call = Task { try await client.execute(request) as Response }
    // Two sleepers: the deadline, and the hold the send is parked on.
    await clock.waitForPendingSleep(count: 2)
    clock.advance(by: short)
    let error = await failure { try await call.value }

    #expect(isDeadline(error))
    // The hold's own deadline is still ahead, so its leaving the clock is the cancellation, and
    // the mock never received the call the hold was in front of.
    #expect(clock.pendingSleeps == 0)
    #expect(mock.requests.isEmpty)
    #expect(clock.sleeps.sorted() == [short, hold])
  }

  @Test("a request within its deadline returns normally and the sleep is cancelled")
  func withinTheDeadlineReturnsNormally() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(
      clock: clock, timeout: long, transport: HoldingTransport(clock: clock, inner: mock))

    let call = Task { try await client.execute(request) as Response }
    await clock.waitForPendingSleep(count: 2)
    clock.advance(by: hold)

    #expect(try await call.value == ok)
    // The deadline had four seconds to run, so its leaving the clock is the cancellation.
    #expect(clock.pendingSleeps == 0)
    #expect(mock.requests.count == 1)
    #expect(clock.sleeps.sorted() == [hold, long])
  }

  @Test("the request's own timeout overrides the client's")
  func requestTimeoutOverridesTheClientTimeout() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(
      clock: clock, timeout: short, transport: HoldingTransport(clock: clock, inner: mock))
    let patient = Request(options: RequestOptions(timeout: long), path: path)

    let call = Task { try await client.execute(patient) as Response }
    await clock.waitForPendingSleep(count: 2)
    // The client's deadline passes with the send still parked; only the request's is armed, so
    // nothing fires, and the hold releases at its own time.
    clock.advance(by: short)
    #expect(clock.pendingSleeps == 2)
    clock.advance(by: hold - short)

    #expect(try await call.value == ok)
    #expect(mock.requests.count == 1)
    #expect(clock.sleeps.sorted() == [hold, long])
  }

  @Test("a deadline is not retried even when the predicate would accept a timeout")
  func aDeadlineIsNeverRetried() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok), .success(ok), .success(ok)])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(
        backoff: BackoffSchedule(delays: [.milliseconds(10)]),
        maxAttempts: 3,
        retryable: { _ in true }),
      timeout: short,
      transport: HoldingTransport(clock: clock, inner: mock))

    let call = Task { try await client.execute(request) as Response }
    await clock.waitForPendingSleep(count: 2)
    clock.advance(by: short)
    let error = await failure { try await call.value }

    #expect(isDeadline(error))
    // One hold and the deadline: no backoff wait was ever asked for, so no second attempt began.
    #expect(clock.sleeps.sorted() == [short, hold])
    #expect(clock.pendingSleeps == 0)
    #expect(mock.requests.isEmpty)
  }

  @Test("a waiter on a coalesced flight times out without ending the flight")
  func aCoalescedWaiterTimesOutAlone() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))
    let key = "person-1"
    let impatient = Request(
      options: RequestOptions(coalescingKey: key, timeout: short), path: path)
    let patient = Request(options: RequestOptions(coalescingKey: key), path: path)

    let leader = Task { try await client.execute(impatient) as Response }
    // The hold parked means the leader registered and its flight reached the transport; the second
    // sleeper is the leader's deadline.
    await clock.waitForPendingSleep(count: 2)
    // No deadline on the joiner, so `Task.immediate` carries it to its park in the live flight
    // before this line returns.
    let joiner = Task.immediate { try await client.execute(patient) as Response }

    clock.advance(by: short)
    let error = await failure { try await leader.value }
    #expect(isDeadline(error))
    // The hold is still parked: the flight the leader started is alive, and nothing was sent yet.
    #expect(clock.pendingSleeps == 1)
    #expect(mock.requests.isEmpty)

    clock.advance(by: hold - short)
    #expect(try await joiner.value == ok)
    #expect(mock.requests.count == 1)
  }

  @Test("stream(_:) applies no deadline, so chunks arrive past it")
  func streamAppliesNoDeadline() async throws {
    let clock = RecordingClock()
    let (chunks, feed) = AsyncStream<Data>.makeStream()
    let mock = MockTransport(answers: [
      .success(MockTransport.Answer(body: { StreamedBody(chunks) }))
    ])
    let client = makeClient(
      clock: clock, timeout: short, transport: HoldingTransport(clock: clock, inner: mock))

    let call = Task { try await client.stream(request) }
    // The hold is the one sleeper: no deadline was armed alongside it.
    await clock.waitForPendingSleep()
    clock.advance(by: hold)
    let body = try await call.value

    // Well past the client's deadline, the body still delivers what the test feeds it.
    clock.advance(by: long)
    var iterator = body.makeAsyncIterator()
    feed.yield(Data("one".utf8))
    #expect(try await iterator.next() == Data("one".utf8))
    clock.advance(by: long)
    feed.yield(Data("two".utf8))
    feed.finish()
    #expect(try await iterator.next() == Data("two".utf8))
    #expect(try await iterator.next() == nil)
    #expect(clock.sleeps == [hold])
    #expect(clock.pendingSleeps == 0)
  }

  @Test(
    "a deadline of zero or less has already passed, so the request fails without waiting",
    arguments: [Duration.zero, .seconds(-1)])
  func aDeadlineOfZeroOrLessFiresAtOnce(limit: Duration) async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(
      clock: clock, timeout: limit, transport: HoldingTransport(clock: clock, inner: mock))

    // Nothing here advances the clock. The send is parked on the hold, so returning at all is the
    // claim: a deadline that waited to be advanced would hang instead of passing.
    let error = await failure { try await client.execute(request) as Response }

    #expect(isDeadline(error))
    #expect(clock.sleeps.contains(limit))
  }
}
