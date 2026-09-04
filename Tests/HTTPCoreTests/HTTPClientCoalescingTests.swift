import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The body every test answers with.
private struct Person: Decodable, Equatable {
  let name: String
}

/// A client over `RecordingClock`, defaulted apart from the arguments given here.
private func makeClient<T: Transport>(
  authentication: Authentication? = nil,
  clock: RecordingClock = RecordingClock(),
  retryPolicy: RetryPolicy = .disabled,
  transport: T
) -> HTTPClient {
  HTTPClient(
    authentication: authentication,
    baseURL: URL.fixture("https://api.example.com"),
    clock: clock,
    retryPolicy: retryPolicy,
    transport: transport
  )
}

/// Whether the failure is ``TransportError/cancelled``.
private func isCancelled(_ error: TransportError?) -> Bool {
  if case .some(.cancelled) = error { true } else { false }
}

/// The status code of a status failure.
private func statusCode(_ error: TransportError?) -> Int? {
  if case .some(.httpStatus(body: _, code: let code, headers: _)) = error { code } else { nil }
}

/// The kind of a transport failure.
private func transportKind(_ error: TransportError?) -> TransportFailureKind? {
  if case .some(.transport(kind: let kind, underlying: _)) = error { kind } else { nil }
}

/// Starts `count` callers, each running synchronously up to its first suspension before the next
/// starts, so every caller has registered under its key by the time this returns. `Task.immediate`
/// is what makes the fan-out order deterministic without a latch.
private func start<Value: Sendable>(
  _ count: Int, _ body: @escaping @Sendable (Int) async throws -> Value
) -> [Task<Value, any Error>] {
  (0..<count).map { index in Task.immediate { try await body(index) } }
}

private let path = "/people/1"
private let request = Request(options: RequestOptions(coalescingKey: "person-1"), path: path)
private let body = Fixtures.jsonObject(["name": "Ada"])
private let ok = Response.ok(json: body)

@Suite("HTTPClient coalescing", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientCoalescingTests {
  @Test("eight concurrent callers under one key produce one send and one shared response")
  func eightCallersOneSend() async throws {
    let callers = 8
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))
    let copy = client

    let calls = start(callers) { index in
      try await (index.isMultiple(of: 2) ? client : copy).execute(request) as Response
    }
    await clock.waitForPendingSleep()
    #expect(mock.requests.isEmpty)
    clock.advanceAll()

    var responses: [Response] = []
    for call in calls {
      responses.append(try await call.value)
    }
    #expect(responses == Array(repeating: ok, count: callers))
    #expect(mock.requests.count == 1)
    #expect(mock.requests.first?.request.path == path)
  }

  @Test("two copies with different bases share one exchange under one key")
  func copiesWithDifferentBasesShareOneExchange() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))
    var copy = client
    copy.baseURL = URL.fixture("https://other.example.com")
    let elsewhere = copy

    // `Task.immediate` runs each caller to its first suspension in turn, so the client is the first
    // arrival and the copy joins the exchange it started.
    let calls = start(2) { index in
      try await (index == 0 ? client : elsewhere).execute(request) as Response
    }
    await clock.waitForPendingSleep()
    clock.advanceAll()

    var responses: [Response] = []
    for call in calls {
      responses.append(try await call.value)
    }
    #expect(responses == [ok, ok])
    #expect(mock.requests.count == 1)
    #expect(mock.requests.first?.request.authority == "api.example.com")
  }

  @Test("two copies with different authentication never share a coalesced flight")
  func copiesWithDifferentAuthenticationNeverShareAFlight() async throws {
    let callers = 20
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok), .success(ok)])
    let client = makeClient(
      authentication: Authentication(provider: RecordingTokenProvider(token: "a")),
      clock: clock,
      transport: HoldingTransport(clock: clock, inner: mock))
    var copy = client
    copy.authentication = Authentication(provider: RecordingTokenProvider(token: "b"))
    let other = copy

    // The key is the caller's own string and carries nothing about credentials, so on the key
    // alone the copy would be handed the response the client fetched under the other token. Ten
    // callers under each credential register before either exchange runs.
    let calls = start(callers) { index in
      try await (index.isMultiple(of: 2) ? client : other).execute(request) as Response
    }
    // Two sleeps means two exchanges: each credential reached the transport rather than one of
    // them parking in the other's flight. A flight's exchange is unstructured, so the wait is what
    // makes the reading settled.
    await clock.waitForPendingSleep(count: 2)
    clock.advanceAll()

    var responses: [Response] = []
    for call in calls {
      responses.append(try await call.value)
    }
    #expect(responses == Array(repeating: ok, count: callers))
    #expect(mock.requests.count == 2)
    // Each flight runs its exchange in a task of its own, so which one reaches the transport first
    // is the executor's to decide; what each copy carried is not.
    #expect(
      Set(mock.requests.map { $0.request.headerFields[.authorization] }) == [
        "Bearer a", "Bearer b",
      ])
  }

  @Test("two copies of one authentication share a coalesced flight")
  func copiesOfOneAuthenticationShareAFlight() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let authentication = Authentication(provider: RecordingTokenProvider(token: "a"))
    let client = makeClient(
      authentication: authentication,
      clock: clock,
      transport: HoldingTransport(clock: clock, inner: mock))
    var copy = client
    copy.authentication?.replayOn401 = false
    let narrowed = copy

    // A rule changed on the copy's value leaves it the same credential, so the copy joins the
    // exchange the client started.
    let calls = start(2) { index in
      try await (index == 0 ? client : narrowed).execute(request) as Response
    }
    await clock.waitForPendingSleep()
    clock.advanceAll()

    var responses: [Response] = []
    for call in calls {
      responses.append(try await call.value)
    }
    #expect(responses == [ok, ok])
    #expect(mock.requests.count == 1)
    #expect(mock.requests.first?.request.headerFields[.authorization] == "Bearer a")
  }

  @Test("an anonymous request and an authenticated one under the same key do not coalesce")
  func anonymousAndAuthenticatedRequestsDoNotCoalesce() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok), .success(ok)])
    let client = makeClient(
      authentication: Authentication(provider: RecordingTokenProvider(token: "a")),
      clock: clock,
      transport: HoldingTransport(clock: clock, inner: mock))
    let anonymous = Request(
      options: RequestOptions(coalescingKey: "person-1", requiresAuth: false), path: path)

    // Same client, same key: only the credential the two requests go out under differs, and that is
    // enough to keep the anonymous caller from being handed a response fetched with the token.
    let calls = start(2) { index in
      try await client.execute(index == 0 ? request : anonymous) as Response
    }
    await clock.waitForPendingSleep(count: 2)
    clock.advanceAll()

    var responses: [Response] = []
    for call in calls {
      responses.append(try await call.value)
    }
    #expect(responses == [ok, ok])
    #expect(mock.requests.count == 2)
    #expect(
      Set(mock.requests.map { $0.request.headerFields[.authorization] }) == [nil, "Bearer a"])
  }

  @Test("a copy pointed at another transport never joins the original's coalesced flight")
  func aCopyPointedAtAnotherTransportDoesNotJoin() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let otherMock = MockTransport(results: [.success(ok)])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))
    var copy = client
    copy.transport = HoldingTransport(clock: clock, inner: otherMock)
    let elsewhere = copy

    // A response fetched through one transport is not the answer to a request bound for another,
    // so the assignment gives the copy a coalescer of its own and each transport sees one send.
    let calls = start(2) { index in
      try await (index == 0 ? client : elsewhere).execute(request) as Response
    }
    await clock.waitForPendingSleep(count: 2)
    clock.advanceAll()

    var responses: [Response] = []
    for call in calls {
      responses.append(try await call.value)
    }
    #expect(responses == [ok, ok])
    #expect(mock.requests.count == 1)
    #expect(otherMock.requests.count == 1)
  }

  @Test("copies taken after a transport assignment share the new coalescer")
  func copiesTakenAfterATransportAssignmentShareTheNewCoalescer() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let otherMock = MockTransport(results: [.success(ok)])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))
    var copy = client
    copy.transport = HoldingTransport(clock: clock, inner: otherMock)
    let first = copy
    let second = copy

    // The assignment made one coalescer, and both copies were taken after it, so the second joins
    // the exchange the first started through the new transport and the original transport is never
    // reached.
    let calls = start(2) { index in
      try await (index == 0 ? first : second).execute(request) as Response
    }
    await clock.waitForPendingSleep()
    clock.advanceAll()

    var responses: [Response] = []
    for call in calls {
      responses.append(try await call.value)
    }
    #expect(responses == [ok, ok])
    #expect(otherMock.requests.count == 1)
    #expect(mock.requests.isEmpty)
  }

  @Test("a nil key never coalesces")
  func nilKeyNeverCoalesces() async throws {
    let callers = 8
    let mock = MockTransport()
    mock.setHandler(forPath: path) { _ in .success(MockTransport.Answer(ok)) }
    let client = makeClient(transport: mock)

    let calls = start(callers) { _ in
      try await client.execute(Request(path: path)) as Response
    }
    for call in calls {
      #expect(try await call.value == ok)
    }
    #expect(mock.requests.count == callers)
  }

  @Test("distinct keys never share an exchange")
  func distinctKeysNeverShare() async throws {
    let callers = 8
    let mock = MockTransport()
    mock.setHandler(forPath: path) { _ in .success(MockTransport.Answer(ok)) }
    let client = makeClient(transport: mock)

    let calls = start(callers) { index in
      try await client.execute(
        Request(options: RequestOptions(coalescingKey: "person-\(index)"), path: path)) as Response
    }
    for call in calls {
      #expect(try await call.value == ok)
    }
    #expect(mock.requests.count == callers)
  }

  @Test("a call after the exchange completed sends again")
  func sequentialCallsSendAgain() async throws {
    let mock = MockTransport(results: [.success(ok), .success(ok)])
    let client = makeClient(transport: mock)

    #expect(try await client.execute(request) as Response == ok)
    #expect(try await client.execute(request) as Response == ok)
    #expect(mock.requests.count == 2)
  }

  @Test("a status failure is delivered to every caller")
  func statusFailureSharedByEveryCaller() async throws {
    let callers = 8
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(.empty(status: .internalServerError))])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))

    let calls = start(callers) { _ in
      try await client.execute(request) as Response
    }
    await clock.waitForPendingSleep()
    clock.advanceAll()

    for call in calls {
      let error = await failure { try await call.value }
      #expect(statusCode(error) == 500)
    }
    #expect(mock.requests.count == 1)
  }

  @Test("a transport failure is delivered to every caller")
  func transportFailureSharedByEveryCaller() async throws {
    let callers = 8
    let clock = RecordingClock()
    let mock = MockTransport(results: [
      .failure(.transport(kind: .connectivity, underlying: nil))
    ])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))

    let calls = start(callers) { _ in
      try await client.execute(request) as Response
    }
    await clock.waitForPendingSleep()
    clock.advanceAll()

    for call in calls {
      let error = await failure { try await call.value }
      #expect(transportKind(error) == .connectivity)
    }
    #expect(mock.requests.count == 1)
  }

  @Test("every entry point shares one exchange and interprets it for itself")
  func everyEntryPointSharesOneSend() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))

    let typed = Task.immediate { try await client.execute(request) as Person }
    let raw = Task.immediate { try await client.execute(request) as Response }
    let none = Task.immediate { try await client.executeExpectingNoContent(request) }
    let headered = Task.immediate {
      try await client.execute(request) as DecodedResponse<Person>
    }
    await clock.waitForPendingSleep()
    clock.advanceAll()

    #expect(try await typed.value == Person(name: "Ada"))
    #expect(try await raw.value == ok)
    try await none.value
    #expect(try await headered.value.value == Person(name: "Ada"))
    #expect(mock.requests.count == 1)
  }

  @Test("the retry loop runs inside the shared exchange")
  func retriesStayInsideOneExchange() async throws {
    let callers = 8
    let clock = RecordingClock()
    let mock = MockTransport(results: [
      .failure(.transport(kind: .timedOut, underlying: nil)), .success(ok),
    ])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(backoff: BackoffSchedule(delays: [.seconds(1)]), maxAttempts: 2),
      transport: mock)

    let calls = start(callers) { _ in
      try await client.execute(request) as Response
    }
    await clock.waitForPendingSleep()
    clock.advanceAll()

    for call in calls {
      #expect(try await call.value == ok)
    }
    #expect(mock.requests.count == 2)
    #expect(clock.sleeps == [.seconds(1)])
  }
}

@Suite("HTTPClient coalescing cancellation", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientCoalescingCancellationTests {
  @Test("a cancelled joiner leaves at once and the exchange finishes for the leader")
  func cancelledJoinerLeavesAtOnce() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))

    let leader = Task.immediate { try await client.execute(request) as Response }
    let joiner = Task.immediate { try await client.execute(request) as Response }
    await clock.waitForPendingSleep()

    // The joiner's failure is awaited before the clock moves. A `.cancelled` that arrived only with
    // the exchange's completion would park this test forever.
    joiner.cancel()
    let error = await failure { try await joiner.value }
    #expect(isCancelled(error))
    #expect(mock.requests.isEmpty)

    clock.advanceAll()
    #expect(try await leader.value == ok)
    #expect(mock.requests.count == 1)
  }

  @Test("a cancelled leader leaves at once and the exchange finishes for the joiner")
  func cancelledLeaderLeavesAtOnce() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))

    let leader = Task.immediate { try await client.execute(request) as Response }
    let joiner = Task.immediate { try await client.execute(request) as Response }
    await clock.waitForPendingSleep()

    leader.cancel()
    let error = await failure { try await leader.value }
    #expect(isCancelled(error))
    #expect(mock.requests.isEmpty)

    clock.advanceAll()
    #expect(try await joiner.value == ok)
    #expect(mock.requests.count == 1)
  }

  @Test("a late arrival joins an exchange every earlier caller has left")
  func lateArrivalJoinsAfterEveryoneLeft() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))

    let first = Task.immediate { try await client.execute(request) as Response }
    let second = Task.immediate { try await client.execute(request) as Response }
    await clock.waitForPendingSleep()

    first.cancel()
    second.cancel()
    #expect(isCancelled(await failure { try await first.value }))
    #expect(isCancelled(await failure { try await second.value }))
    #expect(clock.pendingSleeps == 1)

    let late = Task.immediate { try await client.execute(request) as Response }
    clock.advanceAll()
    #expect(try await late.value == ok)
    #expect(mock.requests.count == 1)
  }

  @Test("a caller already cancelled on arrival neither sends nor joins")
  func alreadyCancelledCallerNeverSends() async throws {
    let mock = MockTransport(results: [.success(ok)])
    let client = makeClient(transport: mock)

    // Cancelling from inside the task, before its first suspension, means the cancellation is already
    // in place when the caller reaches the coalescer.
    let call = Task {
      unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
      return try await client.execute(request) as Response
    }
    let error = await failure { try await call.value }
    #expect(isCancelled(error))
    #expect(mock.requests.isEmpty)

    #expect(try await client.execute(request) as Response == ok)
    #expect(mock.requests.count == 1)
  }
}
