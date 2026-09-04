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

/// A counter a `@Sendable` closure can share. `Mutex` is noncopyable and cannot be captured by value,
/// so a reference type wraps it.
private final class Counter: Sendable {
  private let count = Mutex(0)

  /// The next value, counting from `1`.
  var next: Int {
    count.withLock {
      $0 += 1
      return $0
    }
  }
}

/// A transport that sleeps a span on the injected clock before forwarding each send to a
/// ``MockTransport``. The spans are consumed in call order, and a send past the end of the list waits
/// not at all.
private final class SlowTransport: Transport, Sendable {
  private let clock: RecordingClock
  private let inner: MockTransport
  private let spans: Mutex<[Duration]>

  init(clock: RecordingClock, inner: MockTransport, spans: [Duration]) {
    self.clock = clock
    self.inner = inner
    self.spans = Mutex(spans)
  }

  func send(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> Response
  {
    try await wait()
    return try await inner.send(request, body: body, options: options)
  }

  func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> StreamedResponse
  {
    try await wait()
    return try await inner.stream(request, body: body, options: options)
  }

  /// Sleeps the next seeded span on the injected clock, or not at all past the end of the list.
  private func wait() async throws(TransportError) {
    guard let span = spans.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { return }
    do {
      try await Task.sleep(for: span, tolerance: .zero, clock: clock)
    } catch {
      throw .transport(kind: .other, underlying: error)
    }
  }
}

/// A client over `RecordingClock`, defaulted apart from the arguments given here.
private func makeClient<T: Transport>(
  authentication: Authentication? = nil,
  clock: RecordingClock = RecordingClock(),
  correlationIDField: HTTPField.Name? = nil,
  correlationIDGenerator: @escaping @Sendable () -> String = { "cid" },
  defaultHeaders: HTTPFields = [:],
  observer: RecordingObserver,
  retryPolicy: RetryPolicy = .disabled,
  transport: T
) -> HTTPClient {
  HTTPClient(
    authentication: authentication,
    baseURL: URL.fixture("https://api.example.com"),
    clock: clock,
    correlationIDField: correlationIDField,
    correlationIDGenerator: correlationIDGenerator,
    defaultHeaders: defaultHeaders,
    observer: observer,
    retryPolicy: retryPolicy,
    transport: transport
  )
}

/// The identifier every event carried, in order.
private func correlationIDs(_ events: [RecordingObserver.Event]) -> [String] {
  events.map { event in
    switch event {
    case .failed(let failure): failure.correlationID
    case .finishedBody(let body): body.correlationID
    case .received(let response): response.correlationID
    case .sent(let request): request.correlationID
    }
  }
}

/// The duration each terminal event reported, in order.
private func durations(_ events: [RecordingObserver.Event]) -> [Duration] {
  events.compactMap { event in
    switch event {
    case .failed(let failure): failure.duration
    case .finishedBody: nil
    case .received(let response): response.duration
    case .sent: nil
    }
  }
}

/// The failure events in order.
private func failed(_ events: [RecordingObserver.Event]) -> [FailureEvent] {
  events.compactMap { if case .failed(let event) = $0 { event } else { nil } }
}

/// The response events in order.
private func received(_ events: [RecordingObserver.Event]) -> [ResponseEvent] {
  events.compactMap { if case .received(let event) = $0 { event } else { nil } }
}

/// The request events in order.
private func sent(_ events: [RecordingObserver.Event]) -> [RequestEvent] {
  events.compactMap { if case .sent(let event) = $0 { event } else { nil } }
}

/// The log reduced to what each event is and which attempt it belongs to.
private func shape(_ events: [RecordingObserver.Event]) -> [String] {
  events.map { event in
    switch event {
    case .failed(let failure): "failed(\(failure.attempt))"
    case .finishedBody(let body): "finishedBody(\(body.bytesReceived))"
    case .received(let response): "received(\(response.attempt):\(response.status.code))"
    case .sent(let request): "sent(\(request.attempt))"
    }
  }
}

/// Starts `count` callers, each running synchronously up to its first suspension before the next
/// starts, so every caller has joined the flight by the time this returns.
private func start<Value: Sendable>(
  _ count: Int, _ body: @escaping @Sendable () async throws -> Value
) -> [Task<Value, any Error>] {
  (0..<count).map { _ in Task.immediate { try await body() } }
}

private let backoff = Duration.milliseconds(10)
private let body = Fixtures.jsonObject(["name": "Ada"])
private let ok = Response.ok(json: body)
private let path = "/people/1"
private let request = Request(path: path)
private let timeout = TransportError.transport(kind: .timedOut, underlying: nil)
private let url = URL.fixture("https://api.example.com/people/1")

/// The field the correlation tests carry the identifier in. `HTTPField.Name` has only a failable
/// initializer, so it is built once here.
private let requestIDField = HTTPField.Name("X-Request-ID")

/// A policy that attempts `count` times, waiting the same short backoff between each.
private func retrying(_ count: Int) -> RetryPolicy {
  RetryPolicy(
    backoff: BackoffSchedule(delays: [backoff, backoff]),
    maxAttempts: count,
    retryable: { _ in true })
}

@Suite("HTTPClient observer events", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientObserverTests {
  @Test("a successful request reports one send and the response it produced")
  func successReportsSendAndResponse() async throws {
    let observer = RecordingObserver()
    let transport = MockTransport(results: [.success(ok)])
    let client = makeClient(observer: observer, transport: transport)

    _ = try await client.execute(request) as Response

    #expect(shape(observer.events) == ["sent(1)", "received(1:200)"])
    let outgoing = try #require(sent(observer.events).first)
    #expect(outgoing.method == .get)
    #expect(outgoing.url == url)
    #expect(outgoing.authAttached == false)
    let response = try #require(received(observer.events).first)
    #expect(response.status == .ok)
    #expect(response.url == url)
    #expect(response.bodyPreview == nil)
  }

  @Test("a transport failure reports the send and then the failure, with nothing in between")
  func transportFailureReportsSendAndFailure() async {
    let observer = RecordingObserver()
    let transport = MockTransport(results: [.failure(timeout)])
    let client = makeClient(observer: observer, transport: transport)

    let error = await failure { try await client.executeExpectingNoContent(request) }

    #expect(error?.isTimeout == true)
    #expect(shape(observer.events) == ["sent(1)", "failed(1)"])
    #expect(failed(observer.events).first?.failure.isTimeout == true)
    #expect(failed(observer.events).first?.url == url)
    #expect(failed(observer.events).first?.bodyPreview == nil)
  }

  @Test("a status the client rejects still arrives as a response, never as a failure")
  func statusFailureArrivesAsAResponse() async {
    let observer = RecordingObserver()
    let transport = MockTransport(results: [.success(.empty(status: .notFound))])
    let client = makeClient(observer: observer, transport: transport)

    let error = await failure { try await client.executeExpectingNoContent(request) }

    #expect(error?.statusCode == 404)
    #expect(shape(observer.events) == ["sent(1)", "received(1:404)"])
    #expect(failed(observer.events).isEmpty)
  }

  @Test("every attempt of a retried request reports its own pair, under its own ordinal")
  func retryReportsOnePairPerAttempt() async throws {
    let clock = RecordingClock()
    let observer = RecordingObserver()
    let transport = MockTransport(results: [
      .failure(timeout), .failure(timeout), .success(ok),
    ])
    let client = makeClient(
      clock: clock, observer: observer, retryPolicy: retrying(3), transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    await answerWaits(2, of: clock)
    try await call.value

    #expect(
      shape(observer.events) == [
        "sent(1)", "failed(1)", "sent(2)", "failed(2)", "sent(3)", "received(3:200)",
      ])
  }

  @Test("each event's duration is its own send's, not a running total")
  func durationIsOneSendAlone() async throws {
    let clock = RecordingClock()
    let observer = RecordingObserver()
    let mock = MockTransport(results: [.failure(timeout), .success(ok)])
    let transport = SlowTransport(
      clock: clock, inner: mock, spans: [.milliseconds(250), .milliseconds(30)])
    let client = makeClient(
      clock: clock, observer: observer, retryPolicy: retrying(2), transport: transport)

    let call = Task { try await client.executeExpectingNoContent(request) }
    // Three waits, in order: the first send's span, the backoff between attempts, the second's span.
    await answerWaits(3, of: clock)
    try await call.value

    #expect(durations(observer.events) == [.milliseconds(250), .milliseconds(30)])
    #expect(clock.sleeps == [.milliseconds(250), backoff, .milliseconds(30)])
  }
}

@Suite("HTTPClient observer credentials", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientObserverAuthTests {
  @Test("authAttached says whether a credential actually went out")
  func authAttachedReflectsTheCredential() async throws {
    let authenticated = Request(options: RequestOptions(requiresAuth: true), path: path)
    for (token, attached) in [("t1", true), (nil, false)] as [(String?, Bool)] {
      let observer = RecordingObserver()
      let transport = MockTransport(results: [.success(ok)])
      let client = makeClient(
        authentication: Authentication(provider: RecordingTokenProvider(token: token)),
        observer: observer,
        transport: transport)

      try await client.executeExpectingNoContent(authenticated)

      #expect(sent(observer.events).first?.authAttached == attached)
      #expect(received(observer.events).first?.authAttached == attached)
    }
  }

  @Test("a 401 replay is a second send reported under the same attempt ordinal")
  func replayIsASecondSendUnderOneOrdinal() async throws {
    let observer = RecordingObserver()
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: path) { request in
      request.headerFields[.authorization] == "Bearer t2"
        ? .success(MockTransport.Answer(ok))
        : .success(MockTransport.Answer(.empty(status: .unauthorized)))
    }
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens),
      observer: observer,
      transport: transport
    )

    try await client.executeExpectingNoContent(
      Request(options: RequestOptions(requiresAuth: true), path: path))

    #expect(
      shape(observer.events) == ["sent(1)", "received(1:401)", "sent(1)", "received(1:200)"])
    #expect(sent(observer.events).map(\.authAttached) == [true, true])
    #expect(Set(correlationIDs(observer.events)).count == 1)
  }
}

@Suite("HTTPClient observer body previews", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientObserverPreviewTests {
  @Test("a response body reaches an event truncated to the limit the observer asked for")
  func previewIsTruncatedToTheLimit() async throws {
    let observer = RecordingObserver(bodyPreviewLimit: 4)
    let transport = MockTransport(results: [.success(.text("0123456789"))])
    let client = makeClient(observer: observer, transport: transport)

    try await client.executeExpectingNoContent(request)

    #expect(received(observer.events).first?.bodyPreview == Data("0123".utf8))
  }

  @Test("no limit, a limit of zero, and a negative limit all mean no preview")
  func noPreviewWithoutAPositiveLimit() async throws {
    for limit in [nil, 0, -1] as [Int?] {
      let observer = RecordingObserver(bodyPreviewLimit: limit)
      let transport = MockTransport(results: [.success(.text("0123456789"))])
      let client = makeClient(observer: observer, transport: transport)

      try await client.executeExpectingNoContent(request)

      #expect(received(observer.events).first?.bodyPreview == nil)
    }
  }
}

@Suite("HTTPClient correlation identifier", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientCorrelationTests {
  @Test("one identifier covers every attempt and the replay inside one of them")
  func oneIdentifierPerLogicalRequest() async throws {
    let clock = RecordingClock()
    let identifiers = Counter()
    let observer = RecordingObserver()
    let sends = Counter()
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport()
    // The first attempt never answers, and the second is rejected once before it is accepted, so one
    // request crosses both a retry and a credential replay.
    transport.setHandler(forPath: path) { request in
      guard sends.next > 1 else { return .failure(timeout) }
      return request.headerFields[.authorization] == "Bearer t2"
        ? .success(MockTransport.Answer(ok))
        : .success(MockTransport.Answer(.empty(status: .unauthorized)))
    }
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens),
      clock: clock,
      correlationIDGenerator: { "id-\(identifiers.next)" },
      observer: observer,
      retryPolicy: retrying(2),
      transport: transport
    )

    let call = Task {
      try await client.executeExpectingNoContent(
        Request(options: RequestOptions(requiresAuth: true), path: path))
    }
    await answerWaits(1, of: clock)
    try await call.value

    #expect(
      shape(observer.events) == [
        "sent(1)", "failed(1)", "sent(2)", "received(2:401)", "sent(2)", "received(2:200)",
      ])
    #expect(correlationIDs(observer.events) == Array(repeating: "id-1", count: 6))
  }

  @Test("the identifier is sent under the configured field, and under no field by default")
  func theFieldIsWhatPutsItOnTheWire() async throws {
    let field = try #require(requestIDField)
    let observer = RecordingObserver()
    let transport = MockTransport(results: [.success(ok), .success(ok)])
    let sending = makeClient(
      correlationIDField: field, observer: observer, transport: transport)
    let silent = makeClient(observer: observer, transport: transport)

    try await sending.executeExpectingNoContent(request)
    try await silent.executeExpectingNoContent(request)

    #expect(transport.requests.map { $0.request.headerFields[field] } == ["cid", nil])
    #expect(correlationIDs(observer.events) == Array(repeating: "cid", count: 4))
  }

  @Test("an identifier the caller or the defaults already set is adopted, not replaced")
  func anExistingIdentifierIsAdopted() async throws {
    let field = try #require(requestIDField)
    let observer = RecordingObserver()
    let transport = MockTransport(results: [.success(ok), .success(ok)])
    let fromRequest = makeClient(
      correlationIDField: field, observer: observer, transport: transport)
    let fromDefaults = makeClient(
      correlationIDField: field,
      defaultHeaders: [field: "from-defaults"],
      observer: observer,
      transport: transport
    )

    try await fromRequest.executeExpectingNoContent(
      Request(headers: [field: "from-request"], path: path))
    try await fromDefaults.executeExpectingNoContent(request)

    let carried = transport.requests.map { $0.request.headerFields[field] }
    #expect(carried == ["from-request", "from-defaults"])
    #expect(
      correlationIDs(observer.events) == [
        "from-request", "from-request", "from-defaults", "from-defaults",
      ])
  }
}

@Suite("HTTPClient observer under coalescing", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientObserverCoalescingTests {
  @Test("a coalesced flight reports one send however many callers share it")
  func onlyTheFlightReports() async throws {
    let callers = 4
    let clock = RecordingClock()
    let observer = RecordingObserver()
    let mock = MockTransport(results: [.success(ok)])
    let transport = SlowTransport(clock: clock, inner: mock, spans: [.seconds(1)])
    let client = makeClient(clock: clock, observer: observer, transport: transport)
    let keyed = Request(options: RequestOptions(coalescingKey: "person-1"), path: path)

    let calls = start(callers) { try await client.execute(keyed) as Response }
    await clock.waitForPendingSleep()
    clock.advanceAll()
    for call in calls {
      _ = try await call.value
    }

    #expect(mock.requests.count == 1)
    #expect(shape(observer.events) == ["sent(1)", "received(1:200)"])
  }
}
