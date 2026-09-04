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

/// The failure a body reports part-way through.
private struct Interruption: Error, Equatable {}

private let timeout = TransportError.transport(kind: .timedOut, underlying: nil)

/// A seeded answer delivering `text` as one chunk and then ending cleanly.
private func answer(
  _ text: String,
  headers: HTTPFields = [:],
  status: HTTPResponse.Status = .ok
) -> Result<MockTransport.Answer, TransportError> {
  .success(
    MockTransport.Answer(chunks: [Data(text.utf8)], headers: headers, status: status))
}

/// A seeded answer delivering `text` and then failing with ``Interruption``.
private func interrupted(_ text: String) -> Result<MockTransport.Answer, TransportError> {
  .success(
    MockTransport.Answer(
      chunks: [Data(text.utf8)],
      failure: .transport(kind: .other, underlying: Interruption())))
}

/// A client over ``MockTransport`` and `RecordingClock`, defaulted apart from the arguments given
/// here.
private func makeClient(
  authentication: Authentication? = nil,
  clock: RecordingClock = RecordingClock(),
  correlationIDGenerator: @escaping @Sendable () -> String = { "cid" },
  observer: RecordingObserver? = nil,
  retryPolicy: RetryPolicy = .disabled,
  transport: MockTransport
) -> HTTPClient {
  HTTPClient(
    authentication: authentication,
    baseURL: URL.fixture("https://api.example.com"),
    clock: clock,
    correlationIDGenerator: correlationIDGenerator,
    observer: observer,
    retryPolicy: retryPolicy,
    transport: transport
  )
}

/// The bytes of a body, read to the end.
private func collect(
  _ body: some AsyncSequence<Data, TransportError>
) async throws(TransportError) -> [UInt8] {
  var collected: [UInt8] = []
  for try await chunk in body { collected.append(contentsOf: chunk) }
  return collected
}

/// The status and body of a status failure, or `nil` for any other case.
private func httpStatus(_ error: TransportError) -> (body: Data, code: Int, headers: HTTPFields)? {
  if case .httpStatus(let body, let code, let headers) = error {
    (body: body, code: code, headers: headers)
  } else {
    nil
  }
}

/// Whether the error is ``TransportError/cancelled``.
private func isCancelled(_ error: TransportError) -> Bool {
  if case .cancelled = error { true } else { false }
}

/// The log reduced to what each event is.
private func kinds(_ events: [RecordingObserver.Event]) -> [String] {
  events.map { event in
    switch event {
    case .failed: "failed"
    case .finishedBody: "finishedBody"
    case .received: "received"
    case .sent: "sent"
    }
  }
}

/// The body events in the log, in order.
private func finishedBodies(_ events: [RecordingObserver.Event]) -> [BodyEvent] {
  events.compactMap { event in
    if case .finishedBody(let body) = event { body } else { nil }
  }
}

/// A body delivering one chunk to each iterator and then holding every iterator at its end until
/// `count` of them have arrived, so the ends are reached together.
private struct HeldEnd: AsyncSequence, Sendable {
  typealias Element = Data
  typealias Failure = Never

  let count: Int
  let latch: Latch

  struct AsyncIterator: AsyncIteratorProtocol {
    let count: Int
    let latch: Latch
    var delivered = false

    mutating func next() async -> Data? {
      guard delivered else {
        delivered = true
        return Data("ab".utf8)
      }
      latch.arrive()
      await latch.wait(forCount: count)
      return nil
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(count: count, latch: latch)
  }
}

private let path = "/things"
/// How many chunks a test producer delivers before it gives up on being cancelled.
private let producerCeiling = 4096
private let request = Request(path: path)

@Suite("HTTPClient streaming", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientStreamingTests {
  @Test("a successful response's chunks reach the caller in order")
  func chunksReachTheCaller() async throws {
    let sent = Array("hello world".utf8)
    let transport = MockTransport(answers: [answer("hello world")])
    let client = makeClient(transport: transport)

    let bytes = try await client.stream(request)

    #expect(try await collect(bytes) == sent)
    #expect(transport.requests.count == 1)
    #expect(transport.last?.request.path == path)
  }

  @Test("a copy of a streaming client still streams, over the transport the original holds")
  func aCopyOfAStreamingClientStillStreams() async throws {
    let sent = Array("hello world".utf8)
    let transport = MockTransport(answers: [answer("hello world")])
    let client = makeClient(transport: transport)
    var derived = client
    derived.defaultHeaders[.accept] = "text/event-stream"

    let bytes = try await derived.stream(request)

    #expect(try await collect(bytes) == sent)
    #expect(transport.last?.request.headerFields[.accept] == "text/event-stream")
  }

  @Test("a copy pointed at another transport streams through it")
  func aCopyPointedAtAnotherTransportStreamsThroughIt() async throws {
    let expected = Array("other".utf8)
    let original = MockTransport(answers: [answer("original")])
    let other = MockTransport(answers: [answer("other")])
    let client = makeClient(transport: original)
    var copy = client
    copy.transport = other

    let bytes = try await copy.stream(request)

    #expect(try await collect(bytes) == expected)
    #expect(original.requests.isEmpty)
    #expect(other.requests.map(\.request.path) == [path])
  }

  @Test("a status outside 2xx throws with an error body under the limit whole, and the fields")
  func aFailedStatusThrowsWithTheErrorBody() async throws {
    let transport = MockTransport(answers: [
      .success(
        MockTransport.Answer(
          chunks: [Data(#"{"error":"#.utf8), Data(#""nope"}"#.utf8)],
          headers: [.contentType: "application/json"],
          status: .notFound))
    ])
    let client = makeClient(transport: transport)

    let error = try #require(await failure(of: { try await client.stream(request) }))

    let status = try #require(httpStatus(error))
    #expect(status.code == 404)
    #expect(status.body == Data(#"{"error":"nope"}"#.utf8))
    #expect(status.headers[.contentType] == "application/json")
  }

  @Test("an error body over the limit is truncated at exactly 65,536 bytes")
  func anOversizedErrorBodyIsTruncated() async throws {
    // Two chunks of 48 KiB, so the limit falls inside the second one and the truncation is
    // visible in the bytes rather than only in the count.
    let first = Data(repeating: 0x61, count: 48 * 1024)
    let second = Data(repeating: 0x62, count: 48 * 1024)
    let expected = first + Data(repeating: 0x62, count: 16 * 1024)
    let transport = MockTransport(answers: [
      .success(MockTransport.Answer(chunks: [first, second], status: .internalServerError))
    ])
    let client = makeClient(transport: transport)

    let error = try #require(await failure(of: { try await client.stream(request) }))

    let status = try #require(httpStatus(error))
    #expect(status.code == 500)
    #expect(status.body.count == 65_536)
    #expect(status.body == expected)
  }

  @Test("the read stops at the limit and cancels a producer still delivering the error body")
  func theErrorBodyReadCancelsTheProducer() async throws {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control)
    let transport = MockTransport(answers: [
      .success(
        MockTransport.Answer(body: { buffer.makeBody() }, status: .serviceUnavailable))
    ])
    let client = makeClient(transport: transport)
    // The producer delivers until the buffer stops it, honouring a suspension like any other, so
    // the cancellation is a fact about a producer still running rather than one already done. The
    // ceiling is the backstop: reaching it would mean no cancellation ever arrived.
    let producer = Task {
      var appended = 0
      while !control.calls.contains(.cancel), appended < producerCeiling {
        guard control.calls.last(where: { $0 != .cancel }) != .suspend else {
          await Task.yield()
          continue
        }
        buffer.append(Data(repeating: 0x63, count: 1024))
        appended += 1
        await Task.yield()
      }
      return appended
    }

    let error = try #require(await failure(of: { try await client.stream(request) }))

    let appended = await producer.value
    let status = try #require(httpStatus(error))
    #expect(status.code == 503)
    #expect(status.body == Data(repeating: 0x63, count: 65_536))
    #expect(appended >= 64)
    #expect(appended < producerCeiling)
    #expect(control.calls.contains(.cancel))
  }

  @Test("a failure part-way through the error body leaves the bytes that arrived on the failure")
  func aFailedErrorBodyReadKeepsWhatArrived() async throws {
    let transport = MockTransport(answers: [
      .success(
        MockTransport.Answer(
          chunks: [Data("half".utf8)],
          failure: .transport(kind: .other, underlying: Interruption()),
          status: .badGateway))
    ])
    let client = makeClient(transport: transport)

    let error = try #require(await failure(of: { try await client.stream(request) }))

    let status = try #require(httpStatus(error))
    #expect(status.code == 502)
    #expect(status.body == Data("half".utf8))
  }

  @Test("a caller cancelled while the error body is read leaves with cancelled, not the status")
  func aCallerCancelledMidReadLeavesWithCancelled() async throws {
    let control = CountingControl()
    // Watermarks of zero make the buffer report every handover: it suspends on the chunk waiting
    // to be read and resumes once the read has taken it, which is the point the caller is about
    // to park on a body with nothing more in it.
    let buffer = ChunkBuffer(control: control, highWatermark: 0, lowWatermark: 0)
    buffer.append(Data("partial".utf8))
    let transport = MockTransport(answers: [
      .success(MockTransport.Answer(body: { buffer.makeBody() }, status: .internalServerError))
    ])
    let client = makeClient(transport: transport)

    let reader = Task { await failure(of: { try await client.stream(request) }) }
    await control.wait(for: .resume)
    reader.cancel()

    #expect(isCancelled(try #require(await reader.value)))
    #expect(transport.requests.count == 1)
  }

  @Test("the credential is attached to the send, as it is on a buffered request")
  func theCredentialIsAttached() async throws {
    let transport = MockTransport(answers: [answer("")])
    let client = makeClient(
      authentication: Authentication(provider: RecordingTokenProvider(token: "first")),
      transport: transport)

    _ = try await client.stream(request)

    #expect(transport.last?.request.headerFields[.authorization] == "Bearer first")
  }

  @Test(
    "a 401 is refreshed once and replayed once, and the replay's bytes are what the caller gets")
  func aRejectedStreamIsReplayedOnce() async throws {
    let replayed = Array("second".utf8)
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("second")], token: "first")
    let transport = MockTransport(answers: [
      answer("first", status: .unauthorized), answer("second"),
    ])
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens),
      transport: transport)

    let bytes = try await client.stream(request)

    #expect(try await collect(bytes) == replayed)
    #expect(transport.requests.count == 2)
    #expect(
      transport.requests.map { $0.request.headerFields[.authorization] }
        == ["Bearer first", "Bearer second"])
  }

  @Test("a second 401 is an ordinary status failure, carrying the body the replay was refused with")
  func aSecondRejectionIsAStatusFailure() async throws {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("second")], token: "first")
    let transport = MockTransport(answers: [
      answer("", status: .unauthorized),
      answer(#"{"error":"expired"}"#, status: .unauthorized),
    ])
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens),
      transport: transport)

    let error = try #require(await failure(of: { try await client.stream(request) }))

    let status = try #require(httpStatus(error))
    #expect(status.code == 401)
    #expect(status.body == Data(#"{"error":"expired"}"#.utf8))
    #expect(transport.requests.count == 2)
  }

  @Test("a stream is sent once even under a policy that would retry everything")
  func aStreamIsNeverRetried() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [.failure(timeout)])
    let client = makeClient(
      clock: clock,
      retryPolicy: RetryPolicy(
        backoff: BackoffSchedule(delays: [.milliseconds(10)]), maxAttempts: 3,
        retryable: { _ in true }),
      transport: transport)

    let error = try #require(await failure(of: { try await client.stream(request) }))

    #expect(error.isTimeout)
    #expect(transport.requests.count == 1)
    #expect(clock.sleeps == [])
  }

  @Test("two streams under one coalescing key each make their own request")
  func aCoalescingKeyDoesNotJoinTwoStreams() async throws {
    let transport = MockTransport(answers: [answer("a"), answer("b")])
    let client = makeClient(transport: transport)
    let keyed = Request(options: RequestOptions(coalescingKey: "shared"), path: path)

    let first = try await collect(try await client.stream(keyed))
    let second = try await collect(try await client.stream(keyed))

    #expect(first == Array("a".utf8))
    #expect(second == Array("b".utf8))
    #expect(transport.requests.count == 2)
  }

  @Test("the observer sees the send and the response, with the real status and no body preview")
  func theObserverSeesTheSendAndTheResponse() async throws {
    let observer = RecordingObserver(bodyPreviewLimit: 64)
    let transport = MockTransport(answers: [answer("hello", status: .created)])
    let client = makeClient(observer: observer, transport: transport)

    _ = try await client.stream(request)

    #expect(kinds(observer.events) == ["sent", "received"])
    guard case .received(let received) = try #require(observer.last) else {
      Issue.record("expected a response event, got \(String(describing: observer.last))")
      return
    }
    #expect(received.attempt == 1)
    #expect(received.correlationID == "cid")
    #expect(received.status == .created)
    // Building a preview would consume the stream.
    #expect(received.bodyPreview == nil)
  }

  @Test("a failure before the sequence is handed out is reported")
  func theObserverSeesAFailureBeforeTheHandOut() async throws {
    let observer = RecordingObserver()
    let transport = MockTransport(answers: [.failure(timeout)])
    let client = makeClient(observer: observer, transport: transport)

    _ = await failure(of: { try await client.stream(request) })

    #expect(kinds(observer.events) == ["sent", "failed"])
  }

  @Test("a body read to its end reports one body event with the bytes delivered and no failure")
  func aBodyReadToTheEndReportsOneEvent() async throws {
    let observer = RecordingObserver()
    let transport = MockTransport(answers: [
      .success(
        MockTransport.Answer(chunks: [Data("ab".utf8), Data("cde".utf8), Data("f".utf8)]))
    ])
    let client = makeClient(observer: observer, transport: transport)

    let bytes = try await client.stream(request)
    _ = try await collect(bytes)

    #expect(kinds(observer.events) == ["sent", "received", "finishedBody"])
    let end = try #require(finishedBodies(observer.events).first)
    #expect(end.bytesReceived == 6)
    #expect(end.correlationID == "cid")
    #expect(end.failure == nil)
  }

  @Test("a failure part-way through the body reports one body event carrying it after the chunks")
  func aMidStreamFailureIsReportedOnce() async throws {
    let observer = RecordingObserver()
    let transport = MockTransport(answers: [interrupted("half")])
    let client = makeClient(observer: observer, transport: transport)

    let bytes = try await client.stream(request)
    let error = try #require(await failure(of: { try await collect(bytes) }))

    #expect(error.underlying is Interruption)
    #expect(kinds(observer.events) == ["sent", "received", "finishedBody"])
    let end = try #require(finishedBodies(observer.events).first)
    #expect(end.bytesReceived == 4)
    #expect(end.failure?.underlying is Interruption)
  }

  @Test("a second iterator over a finished body reports nothing more")
  func aFinishedBodyReportsOnce() async throws {
    let observer = RecordingObserver()
    let transport = MockTransport(answers: [answer("hello")])
    let client = makeClient(observer: observer, transport: transport)

    let bytes = try await client.stream(request)
    _ = try await collect(bytes)
    var again = bytes.makeAsyncIterator()
    #expect(try await again.next() == nil)

    #expect(kinds(observer.events) == ["sent", "received", "finishedBody"])
  }

  @Test("two iterators reaching the end of one body together report it once")
  func twoIteratorsReportOnce() async throws {
    let observer = RecordingObserver()
    let latch = Latch()
    let transport = MockTransport(answers: [
      .success(MockTransport.Answer(body: { StreamedBody(HeldEnd(count: 2, latch: latch)) }))
    ])
    let client = makeClient(observer: observer, transport: transport)

    let bytes = try await client.stream(request)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<2 {
        group.addTask {
          var iterator = bytes.makeAsyncIterator()
          while try await iterator.next() != nil {}
        }
      }
      try await group.waitForAll()
    }

    #expect(kinds(observer.events) == ["sent", "received", "finishedBody"])
    #expect(finishedBodies(observer.events).first?.bytesReceived == 2)
  }

  @Test("a body dropped before it ended reports nothing")
  func aDroppedBodyReportsNothing() async throws {
    let observer = RecordingObserver()
    let transport = MockTransport(answers: [
      .success(MockTransport.Answer(chunks: [Data("ab".utf8), Data("cd".utf8)]))
    ])
    let client = makeClient(observer: observer, transport: transport)

    do {
      let bytes = try await client.stream(request)
      var iterator = bytes.makeAsyncIterator()
      #expect(try await iterator.next() == Data("ab".utf8))
    }

    #expect(kinds(observer.events) == ["sent", "received"])
  }

  @Test("a status outside 2xx reports no body event, because no body was handed out")
  func aStatusFailureReportsNoBodyEvent() async throws {
    let observer = RecordingObserver()
    let transport = MockTransport(answers: [answer("nope", status: .notFound)])
    let client = makeClient(observer: observer, transport: transport)

    _ = await failure(of: { try await client.stream(request) })

    #expect(kinds(observer.events) == ["sent", "received"])
  }

  @Test("a consumer cancelled part-way through a body reports the body as cancelled")
  func aCancelledConsumerReportsCancelled() async throws {
    let observer = RecordingObserver()
    let (body, continuation) = AsyncStream<Data>.makeStream()
    defer { continuation.finish() }
    let transport = MockTransport(answers: [
      .success(MockTransport.Answer(body: { StreamedBody(body) }))
    ])
    let client = makeClient(observer: observer, transport: transport)

    let reader = Task.immediate {
      await failure(of: { try await collect(try await client.stream(request)) })
    }
    reader.cancel()

    #expect(isCancelled(try #require(await reader.value)))
    #expect(kinds(observer.events) == ["sent", "received", "finishedBody"])
    let end = try #require(finishedBodies(observer.events).first)
    #expect(end.bytesReceived == 0)
    #expect(end.failure.map(isCancelled) == true)
  }

  @Test("eight concurrent bodies each report exactly one event under their own identifier")
  func eightBodiesReportOnceEach() async throws {
    let observer = RecordingObserver()
    let latch = Latch()
    let minted = Atomic<Int>(0)
    // Every body has its first chunk waiting and is held open until all eight readers have read
    // it, so the eight ends are reached together.
    let bodies = (0..<8).map { _ in AsyncStream<Data>.makeStream() }
    for (_, continuation) in bodies { continuation.yield(Data("ab".utf8)) }
    let transport = MockTransport(
      answers: bodies.map { stream, _ in
        .success(MockTransport.Answer(body: { StreamedBody(stream) }))
      })
    let client = makeClient(
      correlationIDGenerator: { "c\(minted.wrappingAdd(1, ordering: .relaxed).oldValue)" },
      observer: observer, transport: transport)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          let bytes = try await client.stream(request)
          var iterator = bytes.makeAsyncIterator()
          _ = try await iterator.next()
          latch.arrive()
          while try await iterator.next() != nil {}
        }
      }
      await latch.wait(forCount: 8)
      for (_, continuation) in bodies {
        continuation.yield(Data("cde".utf8))
        continuation.finish()
      }
      try await group.waitForAll()
    }

    let ends = finishedBodies(observer.events)
    #expect(ends.count == 8)
    #expect(Set(ends.map(\.correlationID)) == Set((0..<8).map { "c\($0)" }))
    #expect(ends.allSatisfy { $0.bytesReceived == 5 && $0.failure == nil })
  }

  @Test("a caller cancelled before it streams leaves with cancelled")
  func aCancelledCallerLeavesWithCancelled() async throws {
    let transport = MockTransport(answers: [answer("hello")])
    let client = makeClient(transport: transport)

    // A task added to an already-cancelled group starts cancelled, which is deterministic where
    // racing a `cancel()` fired alongside it is not.
    let outcome = await withTaskGroup(of: TransportError?.self) { group in
      group.cancelAll()
      group.addTask {
        await failure(of: { try await collect(try await client.stream(request)) })
      }
      return await group.next() ?? nil
    }

    #expect(isCancelled(try #require(outcome)))
  }

  @Test("a consumer parked on a body that never delivers leaves with cancelled")
  func aParkedConsumerLeavesWithCancelled() async throws {
    // A body nothing ever yields into. `AsyncStream` finishes as soon as its continuation is
    // released, so the test holds the continuation for as long as the body must stay parked.
    let (body, continuation) = AsyncStream<Data>.makeStream()
    defer { continuation.finish() }
    let transport = MockTransport(answers: [
      .success(MockTransport.Answer(body: { StreamedBody(body) }))
    ])
    let client = makeClient(transport: transport)

    // `Task.immediate` runs to the first suspension synchronously, so the consumer is parked on the
    // body before `cancel()` arrives.
    let reader = Task.immediate {
      await failure(of: { try await collect(try await client.stream(request)) })
    }
    reader.cancel()

    #expect(isCancelled(try #require(await reader.value)))
    #expect(transport.requests.count == 1)
  }
}
