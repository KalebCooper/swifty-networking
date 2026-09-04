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

/// A request at `path`. A `nil` path is the one case the handler table cannot key on.
private func request(path: String?) -> HTTPRequest {
  HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: path)
}

/// A response whose body is `text`.
private func response(_ text: String, status: HTTPResponse.Status = .ok) -> Response {
  Response(body: Data(text.utf8), status: status)
}

/// An answer delivering a response whose body is `text`.
private func answer(_ text: String, status: HTTPResponse.Status = .ok) -> MockTransport.Answer {
  MockTransport.Answer(response(text, status: status))
}

/// The body as a string.
private func text(_ response: Response) -> String {
  String(decoding: response.body, as: UTF8.self)
}

/// A `Mutex`-backed sink a handler can close over. `Mutex` is noncopyable and a closure capturing one
/// directly consumes it, so a reference type wraps it.
private final class Recorder<Value: Sendable>: Sendable {
  private let state = Mutex<[Value]>([])

  var count: Int { state.withLock { $0.count } }

  var values: [Value] { state.withLock { $0 } }

  func append(_ value: Value) {
    state.withLock { $0.append(value) }
  }
}

/// An answer whose body is `text`, seeded as the one chunk it arrives in.
private func streamed(_ text: String, status: HTTPResponse.Status = .ok) -> MockTransport.Answer {
  MockTransport.Answer(chunks: [Data(text.utf8)], status: status)
}

/// The body of a streamed response, read to the end and decoded.
private func text(_ response: StreamedResponse) async throws -> String {
  var bytes: [UInt8] = []
  for try await chunk in response.body { bytes.append(contentsOf: chunk) }
  return String(decoding: bytes, as: UTF8.self)
}

/// The chunks of a streamed response, exactly as the body delivered them.
private func chunks(_ response: StreamedResponse) async throws -> [Data] {
  var chunks: [Data] = []
  for try await chunk in response.body { chunks.append(chunk) }
  return chunks
}

/// Asserts that `body` fails with ``MockTransportFailure/noCannedResponse``.
private func expectNoCannedResponse<Value>(
  _ body: () async throws -> Value,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  do {
    _ = try await body()
    Issue.record("the call should have thrown", sourceLocation: sourceLocation)
  } catch let error as TransportError {
    guard case .transport(kind: let kind, underlying: let underlying) = error else {
      Issue.record("expected a transport failure, got \(error)", sourceLocation: sourceLocation)
      return
    }
    #expect(kind == .other, sourceLocation: sourceLocation)
    #expect(
      underlying as? MockTransportFailure == .noCannedResponse, sourceLocation: sourceLocation)
  } catch {
    Issue.record("expected a TransportError, got \(error)", sourceLocation: sourceLocation)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct MockTransportQueueTests {
  @Test("Queued results are handed out in the order they were seeded, failures included")
  func queueIsFIFO() async throws {
    let transport = MockTransport(results: [
      .success(response("first")),
      .failure(.transport(kind: .timedOut, underlying: nil)),
      .success(response("third")),
    ])

    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "first")
    do {
      _ = try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())
      Issue.record("the second result should have thrown")
    } catch {
      let typed: TransportError = error
      #expect(typed.isTimeout)
    }
    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "third")
  }

  @Test("enqueue(_:) adds to the back of whatever the initializer seeded")
  func enqueueAppends() async throws {
    let transport = MockTransport(results: [.success(response("first"))])
    transport.enqueue(.success(answer("second")))
    transport.enqueue(.success(answer("third")))

    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "first")
    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "second")
    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "third")
  }

  @Test("One answer queued twice serves two requests with full bodies")
  func oneAnswerServesEveryDeliveryItIsQueuedFor() async throws {
    let seeded = MockTransport.Answer(chunks: [Data("one ".utf8), Data("two".utf8)])
    let transport = MockTransport(answers: [.success(seeded), .success(seeded)])

    #expect(
      try await text(
        transport.stream(request(path: "/a"), body: .none, options: TransportOptions()))
        == "one two")
    #expect(
      try await text(
        transport.stream(request(path: "/a"), body: .none, options: TransportOptions()))
        == "one two")
  }

  @Test("Results and answers share one queue in the order given")
  func resultsAndAnswersShareOneQueue() async throws {
    let transport = MockTransport(
      answers: [.success(streamed("third")), .success(streamed("fourth"))],
      results: [.success(response("first")), .success(response("second"))]
    )
    transport.enqueue(.success(streamed("fifth")))
    transport.enqueue(.success(answer("sixth")))

    var served: [String] = []
    for _ in 0..<6 {
      served.append(
        text(
          try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())))
    }

    #expect(served == ["first", "second", "third", "fourth", "fifth", "sixth"])
  }

  @Test("A failure enqueued behind an answer fails the send that reaches it")
  func anEnqueuedFailureFailsItsSend() async throws {
    let transport = MockTransport(results: [.success(response("first"))])
    transport.enqueue(.failure(.transport(kind: .timedOut, underlying: nil)))

    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "first")
    do {
      _ = try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())
      Issue.record("the enqueued failure should have thrown")
    } catch {
      let typed: TransportError = error
      #expect(typed.isTimeout)
    }
  }

  @Test("An exhausted queue fails with the mock's own reason, matchable by a consumer")
  func exhaustionIsTyped() async {
    let transport = MockTransport(results: [.success(response("only"))])
    _ = try? await transport.send(request(path: "/a"), body: .none, options: TransportOptions())

    await expectNoCannedResponse {
      try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())
    }
  }

  @Test("A transport seeded with nothing fails on its first request")
  func emptyFromTheStart() async {
    let transport = MockTransport()
    await expectNoCannedResponse {
      try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())
    }
  }

  @Test("A canned non-2xx is returned as a response, never thrown")
  func nonSuccessStatusIsAResponse() async throws {
    let transport = MockTransport(results: [
      .success(response("nope", status: .notFound)),
      .success(response("bang", status: .internalServerError)),
    ])

    let notFound = try await transport.send(
      request(path: "/a"), body: .none, options: TransportOptions())
    #expect(notFound.status == .notFound)
    #expect(text(notFound) == "nope")
    #expect(
      try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()).status
        == .internalServerError)
  }

  @Test("A send from a nonisolated context is served like any other")
  func callableFromNonisolatedContext() async throws {
    let transport = MockTransport(results: [.success(response("nonisolated"))])
    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "nonisolated")
  }

  @Test("A send from the main actor is served like any other")
  @MainActor
  func callableFromMainActor() async throws {
    let transport = MockTransport(results: [.success(response("main"))])
    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "main")
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct MockTransportHandlerTests {
  @Test("A handler answers its own path while the queue answers every other")
  func handlerServesItsPathAndQueueServesTheRest() async throws {
    let transport = MockTransport(results: [.success(response("queued"))])
    transport.setHandler(forPath: "/a") { _ in .success(answer("handled")) }

    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "handled")
    #expect(
      text(try await transport.send(request(path: "/b"), body: .none, options: TransportOptions()))
        == "queued")
  }

  @Test("A handler for the request's path wins, and the queue it beat is still intact")
  func handlerWinsWithoutConsumingTheQueue() async throws {
    let transport = MockTransport(results: [.success(response("queued"))])
    transport.setHandler(forPath: "/a") { _ in .success(answer("handled")) }

    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "handled")
    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "handled")
    #expect(
      text(try await transport.send(request(path: "/b"), body: .none, options: TransportOptions()))
        == "queued")
    await expectNoCannedResponse {
      try await transport.send(request(path: "/b"), body: .none, options: TransportOptions())
    }
  }

  @Test("A handler sees the request it was called for")
  func handlerReceivesTheRequest() async throws {
    let transport = MockTransport()
    transport.setHandler(forPath: "/a") { request in
      .success(answer(request.method.rawValue + " " + (request.path ?? "")))
    }

    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "GET /a")
  }

  @Test("A handler may fail, and its failure reaches the caller unchanged")
  func handlerCanFail() async {
    let transport = MockTransport()
    transport.setHandler(forPath: "/a") { _ in .failure(.cancelled) }

    do {
      _ = try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())
      Issue.record("the handler's failure should have thrown")
    } catch {
      let typed: TransportError = error
      #expect(typed.description == "cancelled")
    }
  }

  @Test("Registering a second handler for a path replaces the first")
  func handlerIsReplaced() async throws {
    let transport = MockTransport()
    transport.setHandler(forPath: "/a") { _ in .success(answer("old")) }
    transport.setHandler(forPath: "/a") { _ in .success(answer("new")) }

    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "new")
  }

  @Test("A request with no path matches no handler and falls to the queue")
  func pathlessRequestFallsToTheQueue() async throws {
    let transport = MockTransport(results: [.success(response("queued"))])
    transport.setHandler(forPath: "") { _ in .success(answer("handled")) }

    #expect(
      text(try await transport.send(request(path: nil), body: .none, options: TransportOptions()))
        == "queued")
    await expectNoCannedResponse {
      try await transport.send(request(path: nil), body: .none, options: TransportOptions())
    }
  }

  @Test("A handler registered for a path answers a send whose target carries a query")
  func handlerMatchesThePathWithoutItsQueryOnASend() async throws {
    let transport = MockTransport()
    transport.setHandler(forPath: "/a") { _ in .success(answer("handled")) }

    #expect(
      text(
        try await transport.send(request(path: "/a?x=1"), body: .none, options: TransportOptions()))
        == "handled")
  }

  @Test("A handler registered for a path answers a request that carries a query")
  func handlerMatchesThePathWithoutItsQuery() async throws {
    let transport = MockTransport()
    transport.setHandler(forPath: "/me") { request in .success(answer(request.path ?? "")) }
    let client = HTTPClient(
      baseURL: try #require(URL(string: "https://example.com")),
      clock: RecordingClock(),
      transport: transport
    )

    let received = try await client.execute(
      Request(path: "/me", query: [QueryItem(name: "x", value: "1")]))

    // The body is the path the handler was given, so this also shows the handler sees the query.
    #expect(text(received) == "/me?x=1")
  }

  @Test("A handler key that carries a query matches nothing")
  func handlerKeyCarryingAQueryNeverMatches() async throws {
    let transport = MockTransport(results: [
      .success(response("queued")), .success(response("queued")),
    ])
    transport.setHandler(forPath: "/a?x=1") { _ in .success(answer("handled")) }

    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "queued")
    #expect(
      text(
        try await transport.send(request(path: "/a?x=1"), body: .none, options: TransportOptions()))
        == "queued")
  }

  @Test("A handler runs outside the lock, so it can read what the transport has recorded")
  func handlerCanReadTheLog() async throws {
    let transport = MockTransport()
    let counts = Recorder<Int>()
    transport.setHandler(forPath: "/a") { _ in
      counts.append(transport.requests.count)
      return .success(answer("handled"))
    }

    _ = try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())
    _ = try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())
    #expect(counts.values == [1, 2])
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct MockTransportRecordingTests {
  @Test("Every call is recorded in order, with the body and options it carried")
  func callsAreRecordedInOrder() async throws {
    let transport = MockTransport(results: [
      .success(response("first")), .success(response("second")),
    ])
    let payload = Data("payload".utf8)

    _ = try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())
    _ = try await transport.send(
      request(path: "/b"), body: .bytes(payload), options: TransportOptions(cachePolicy: .cacheOnly)
    )

    #expect(transport.requests.count == 2)
    #expect(transport.requests.map(\.request.path) == ["/a", "/b"])
    #expect(transport.requests.map(\.body) == [.none, .bytes(payload)])
    #expect(
      transport.requests == [
        MockTransport.Call(body: .none, options: TransportOptions(), request: request(path: "/a")),
        MockTransport.Call(
          body: .bytes(payload), options: TransportOptions(cachePolicy: .cacheOnly),
          request: request(path: "/b")),
      ])
  }

  @Test("A buffered request through the mock is recorded once")
  func aBufferedRequestIsRecordedOnce() async throws {
    let transport = MockTransport(results: [.success(response("body"))])

    let received = try await transport.send(
      request(path: "/a"), body: .none, options: TransportOptions())

    #expect(text(received) == "body")
    #expect(transport.requests.count == 1)
    #expect(transport.last?.request.path == "/a")
  }

  @Test("A call that exhausted the queue is recorded too")
  func failedCallIsRecorded() async {
    let transport = MockTransport()
    await expectNoCannedResponse {
      try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())
    }

    #expect(transport.requests.count == 1)
    #expect(transport.last?.request.path == "/a")
  }

  @Test("last is nil before any call and the newest one after each")
  func lastTracksTheNewestCall() async throws {
    let transport = MockTransport(results: [
      .success(response("first")), .success(response("second")),
    ])
    #expect(transport.last == nil)

    _ = try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())
    #expect(transport.last?.request.path == "/a")

    _ = try await transport.send(
      request(path: "/b"), body: .bytes(Data("payload".utf8)), options: TransportOptions())
    #expect(transport.last?.request.path == "/b")
    #expect(transport.last?.body == .bytes(Data("payload".utf8)))
  }

  @Test("reset() clears the log, the queue, and the handlers alike")
  func resetReturnsToFreshState() async throws {
    let transport = MockTransport(results: [.success(response("queued"))])
    transport.setHandler(forPath: "/a") { _ in .success(answer("handled")) }
    _ = try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())

    transport.reset()

    #expect(transport.requests.isEmpty)
    #expect(transport.last == nil)
    await expectNoCannedResponse {
      try await transport.send(request(path: "/a"), body: .none, options: TransportOptions())
    }
    await expectNoCannedResponse {
      try await transport.send(request(path: "/b"), body: .none, options: TransportOptions())
    }
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct MockTransportConcurrencyTests {
  @Test("A burst of concurrent sends consumes each queued result exactly once")
  func concurrentSendsEachTakeOneResult() async {
    let bodies = (0..<8).map { "canned \($0)" }
    let transport = MockTransport(results: bodies.map { .success(response($0)) })

    let received = await withTaskGroup(of: String?.self) { group in
      for _ in bodies {
        group.addTask {
          (try? await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
            .map(text)
        }
      }
      var seen: [String] = []
      for await body in group {
        if let body { seen.append(body) }
      }
      return seen
    }

    #expect(received.count == bodies.count)
    #expect(Set(received) == Set(bodies))
    #expect(transport.requests.count == bodies.count)
  }

  @Test("A handler returning one answer serves a burst of ten with full bodies")
  func oneHandlerAnswerServesABurstWithFullBodies() async throws {
    let seeded = MockTransport.Answer(chunks: [Data("one ".utf8), Data("two".utf8)])
    let transport = MockTransport()
    transport.setHandler(forPath: "/a") { _ in .success(seeded) }

    let received = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<10 {
        group.addTask {
          let response = try await transport.stream(
            request(path: "/a"), body: .none, options: TransportOptions())
          return try await text(response)
        }
      }
      return try await group.reduce(into: [String]()) { $0.append($1) }
    }

    #expect(received == Array(repeating: "one two", count: 10))
    #expect(transport.requests.count == 10)
  }

  @Test("A send read under cancellation leaves with cancelled")
  func aCancelledSendLeavesWithCancelled() async throws {
    let transport = MockTransport(results: [.success(response("body"))])

    // A task added to an already-cancelled group starts cancelled, which is deterministic where
    // racing a `cancel()` fired alongside it is not.
    let outcome = await withTaskGroup(of: TransportError?.self) { group in
      group.cancelAll()
      group.addTask {
        do throws(TransportError) {
          _ = try await transport.send(
            request(path: "/a"), body: .none, options: TransportOptions())
          return nil
        } catch {
          return error
        }
      }
      return await group.next() ?? nil
    }

    #expect(try #require(outcome).description == "cancelled")
    #expect(transport.requests.count == 1)
  }

  @Test("One handler serves a burst of concurrent callers, and logs every one")
  func concurrentSendsShareOneHandler() async {
    let transport = MockTransport()
    let calls = Recorder<String>()
    transport.setHandler(forPath: "/a") { request in
      calls.append(request.path ?? "")
      return .success(answer("handled"))
    }

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          _ = try? await transport.send(
            request(path: "/a"), body: .none, options: TransportOptions())
        }
      }
    }

    #expect(calls.count == 8)
    #expect(calls.values.allSatisfy { $0 == "/a" })
    #expect(transport.requests.count == 8)
    #expect(transport.requests.allSatisfy { $0.request.path == "/a" })
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct MockTransportStreamingTests {
  @Test("Seeded answers reach a stream in the order they were seeded, failures included")
  func theQueueIsFIFOOnTheStreamSurface() async throws {
    let transport = MockTransport(answers: [
      .success(streamed("first")),
      .failure(.transport(kind: .timedOut, underlying: nil)),
      .success(streamed("third")),
    ])

    #expect(
      try await text(
        transport.stream(request(path: "/a"), body: .none, options: TransportOptions())) == "first")
    await #expect(throws: TransportError.self) {
      try await transport.stream(request(path: "/a"), body: .none, options: TransportOptions())
    }
    #expect(
      try await text(
        transport.stream(request(path: "/a"), body: .none, options: TransportOptions())) == "third")
  }

  @Test("A body seeded as several chunks arrives as those chunks, in order, empty ones included")
  func chunksArriveAsGiven() async throws {
    let seeded = [Data("one ".utf8), Data(), Data("two ".utf8), Data("three".utf8)]
    let transport = MockTransport(answers: [
      .success(MockTransport.Answer(chunks: seeded))
    ])

    #expect(
      try await chunks(
        transport.stream(request(path: "/a"), body: .none, options: TransportOptions())) == seeded)
  }

  @Test("A seeded status and its header fields arrive ahead of the body")
  func statusAndHeadersArriveFirst() async throws {
    let transport = MockTransport(answers: [
      .success(
        MockTransport.Answer(
          chunks: [Data("data: hi\n\n".utf8)],
          headers: [.contentType: "text/event-stream"],
          status: .created))
    ])

    let response = try await transport.stream(
      request(path: "/a"), body: .none, options: TransportOptions())

    #expect(response.status == .created)
    #expect(response.headers[.contentType] == "text/event-stream")
    #expect(try await text(response) == "data: hi\n\n")
  }

  @Test("A seeded failure arrives from the body, after the bytes seeded ahead of it")
  func aMidBodyFailureFollowsItsBytes() async throws {
    let transport = MockTransport(answers: [
      .success(
        MockTransport.Answer(
          chunks: [Data("half".utf8)],
          failure: .transport(kind: .timedOut, underlying: nil)))
    ])

    let response = try await transport.stream(
      request(path: "/a"), body: .none, options: TransportOptions())

    var delivered: [UInt8] = []
    do {
      for try await chunk in response.body { delivered.append(contentsOf: chunk) }
      Issue.record("the body should have failed")
    } catch {
      if case .transport(let kind, let underlying) = error {
        #expect(kind == .timedOut)
        #expect(underlying == nil)
      } else {
        Issue.record("expected the seeded timeout, got \(error)")
      }
    }
    #expect(delivered == Array("half".utf8))
  }

  @Test("An unanswered stream fails with the mock's own reason, as an unanswered send does")
  func anUnansweredStreamIsNamed() async {
    let transport = MockTransport()

    await expectNoCannedResponse {
      try await transport.stream(request(path: "/a"), body: .none, options: TransportOptions())
    }
  }

  @Test("A handler answers a streamed request at its path while the queue answers every other")
  func theHandlerBeatsTheQueueOnTheStreamSurface() async throws {
    let transport = MockTransport(answers: [.success(streamed("queued"))])
    transport.setHandler(forPath: "/a") { _ in .success(streamed("handled")) }

    #expect(
      try await text(
        transport.stream(request(path: "/a"), body: .none, options: TransportOptions()))
        == "handled")
    #expect(
      try await text(
        transport.stream(request(path: "/b"), body: .none, options: TransportOptions())) == "queued"
    )
  }

  @Test("One handler answers a send and a stream alike")
  func oneHandlerAnswersBothSurfaces() async throws {
    let transport = MockTransport()
    transport.setHandler(forPath: "/a") { _ in .success(streamed("handled")) }

    #expect(
      text(try await transport.send(request(path: "/a"), body: .none, options: TransportOptions()))
        == "handled")
    #expect(
      try await text(
        transport.stream(request(path: "/a"), body: .none, options: TransportOptions()))
        == "handled")
  }

  @Test("A streamed call is recorded like a sent one, with the body it carried")
  func streamedCallsAreRecorded() async throws {
    let transport = MockTransport(answers: [.success(streamed("first"))])

    _ = try await transport.stream(
      request(path: "/a"), body: .bytes(Data("payload".utf8)), options: TransportOptions())
    await expectNoCannedResponse {
      try await transport.stream(request(path: "/b"), body: .none, options: TransportOptions())
    }

    #expect(transport.requests.count == 2)
    #expect(transport.requests.first?.body == .bytes(Data("payload".utf8)))
    #expect(transport.last?.request.path == "/b")
  }

  @Test("A burst of concurrent streams consumes each seeded answer exactly once")
  func concurrentStreamsEachTakeOneAnswer() async {
    let bodies = (0..<8).map { "seeded \($0)" }
    let transport = MockTransport(answers: bodies.map { .success(streamed($0)) })

    let received = await withTaskGroup(of: String?.self) { group in
      for _ in bodies {
        group.addTask {
          guard
            let response = try? await transport.stream(
              request(path: "/a"), body: .none, options: TransportOptions())
          else {
            return nil
          }
          return try? await text(response)
        }
      }
      var seen: [String] = []
      for await body in group {
        if let body { seen.append(body) }
      }
      return seen
    }

    #expect(received.count == bodies.count)
    #expect(Set(received) == Set(bodies))
    #expect(transport.requests.count == bodies.count)
  }
}
