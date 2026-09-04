import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

private let connectivity = TransportError.transport(kind: .connectivity, underlying: nil)

/// A seeded answer delivering `text` as one chunk and then ending cleanly.
private func answer(
  _ text: String, status: HTTPResponse.Status = .ok
) -> Result<MockTransport.Answer, TransportError> {
  .success(MockTransport.Answer(chunks: [Data(text.utf8)], status: status))
}

/// A seeded answer delivering `text` and then failing with a connectivity failure.
private func dropped(_ text: String) -> Result<MockTransport.Answer, TransportError> {
  .success(MockTransport.Answer(chunks: [Data(text.utf8)], failure: connectivity))
}

/// The data of every event, in order.
private func data(_ events: [ServerSentEvent]) -> [String] {
  events.map(\.data)
}

/// Reads `count` events and stops, so a sequence that never ends on its own can be read to a
/// point.
private func collect(
  _ count: Int, from events: EventSource
) async throws(TransportError) -> [ServerSentEvent] {
  var collected: [ServerSentEvent] = []
  for try await event in events {
    collected.append(event)
    if collected.count == count { break }
  }
  return collected
}

/// Whether the error is ``TransportError/cancelled``.
private func isCancelled(_ error: TransportError) -> Bool {
  if case .cancelled = error { true } else { false }
}

/// The `Last-Event-ID` value each recorded call carried, or `nil` where it carried none.
private func lastEventIDs(_ transport: MockTransport) throws -> [String?] {
  let field = try #require(HTTPField.Name("Last-Event-ID"))
  return transport.requests.map { $0.request.headerFields[field] }
}

/// A client over ``MockTransport`` and `RecordingClock`.
private func makeClient(
  clock: RecordingClock, observer: RecordingObserver? = nil, transport: MockTransport
) -> HTTPClient {
  HTTPClient(
    baseURL: URL.fixture("https://api.example.com"), clock: clock, observer: observer,
    transport: transport)
}

/// The body events in the log, in order.
private func finishedBodies(_ events: [RecordingObserver.Event]) -> [BodyEvent] {
  events.compactMap { event in
    if case .finishedBody(let body) = event { body } else { nil }
  }
}

private let path = "/events"
private let request = Request(path: path)

@Suite("EventSource", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct EventSourceTests {
  @Test("a stream that ends cleanly is reconnected after the server's retry with Last-Event-ID set")
  func aCleanEndReconnectsWithTheLastEventID() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [
      answer("id: 1\nretry: 250\ndata: a\n\n"), answer("data: b\n\n"),
    ])
    let client = makeClient(clock: clock, transport: transport)

    let reader = Task { try await collect(2, from: client.events(request)) }
    await answerWaits(1, of: clock)

    #expect(data(try await reader.value) == ["a", "b"])
    #expect(clock.sleeps == [.milliseconds(250)])
    #expect(try lastEventIDs(transport) == [nil, "1"])
  }

  @Test("a transport failure part-way through the body reconnects after the default three seconds")
  func aMidBodyFailureReconnectsAfterTheDefaultDelay() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [dropped("id: 7\ndata: a\n\n"), answer("data: b\n\n")])
    let client = makeClient(clock: clock, transport: transport)

    let reader = Task { try await collect(2, from: client.events(request)) }
    await answerWaits(1, of: clock)

    #expect(data(try await reader.value) == ["a", "b"])
    #expect(clock.sleeps == [.seconds(3)])
    #expect(try lastEventIDs(transport) == [nil, "7"])
  }

  @Test("each connection reports its own body end to the observer under a fresh identifier")
  func eachConnectionReportsItsOwnBodyEnd() async throws {
    let clock = RecordingClock()
    let observer = RecordingObserver()
    // The third body is still open when the reader stops, so it is dropped and reports nothing;
    // the two connections that ended each report once.
    let transport = MockTransport(answers: [
      dropped("data: a\n\n"), dropped("data: bb\n\n"), answer("data: c\n\n"),
    ])
    let client = makeClient(clock: clock, observer: observer, transport: transport)

    let reader = Task { try await collect(3, from: client.events(request)) }
    await answerWaits(2, of: clock)
    _ = try await reader.value

    let ends = finishedBodies(observer.events)
    #expect(ends.map(\.bytesReceived) == [9, 10])
    #expect(
      ends.map { $0.failure?.description } == [connectivity.description, connectivity.description])
    #expect(Set(ends.map(\.correlationID)).count == 2)
  }

  @Test("a first connection that fails with a transport failure is tried again after the delay")
  func aFailedFirstConnectionIsTriedAgain() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [.failure(connectivity), answer("data: a\n\n")])
    let client = makeClient(clock: clock, transport: transport)

    let reader = Task { try await collect(1, from: client.events(request)) }
    await answerWaits(1, of: clock)

    #expect(data(try await reader.value) == ["a"])
    #expect(clock.sleeps == [.seconds(3)])
    #expect(try lastEventIDs(transport) == [nil, nil])
  }

  @Test("the reconnect delay given to events(_:) is used until the server sends a retry")
  func theGivenDelayIsUsedUntilTheServerSendsARetry() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [
      answer("data: a\n\n"), answer("retry: 500\ndata: b\n\n"), answer("data: c\n\n"),
    ])
    let client = makeClient(clock: clock, transport: transport)

    let reader = Task {
      try await collect(3, from: client.events(request, reconnectDelay: .seconds(1)))
    }
    await answerWaits(2, of: clock)

    #expect(data(try await reader.value) == ["a", "b", "c"])
    #expect(clock.sleeps == [.seconds(1), .milliseconds(500)])
  }

  @Test("a retry holds for every later reconnect until the server sends another")
  func aRetryHoldsAcrossReconnects() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [
      answer("retry: 250\ndata: a\n\n"), answer("data: b\n\n"), answer("data: c\n\n"),
    ])
    let client = makeClient(clock: clock, transport: transport)

    let reader = Task { try await collect(3, from: client.events(request)) }
    await answerWaits(2, of: clock)

    #expect(data(try await reader.value) == ["a", "b", "c"])
    #expect(clock.sleeps == [.milliseconds(250), .milliseconds(250)])
  }

  @Test("a retry sent in a frame with no data is waited before the reconnect")
  func aRetryWithoutDataIsWaited() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [answer("retry: 250\n\n"), answer("data: a\n\n")])
    let client = makeClient(clock: clock, transport: transport)

    let reader = Task { try await collect(1, from: client.events(request)) }
    await answerWaits(1, of: clock)

    #expect(data(try await reader.value) == ["a"])
    #expect(clock.sleeps == [.milliseconds(250)])
  }

  @Test("an id sent in a frame with no data is carried on the reconnect")
  func anIDWithoutDataIsCarried() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [answer("id: 9\n\n"), answer("data: a\n\n")])
    let client = makeClient(clock: clock, transport: transport)

    let reader = Task { try await collect(1, from: client.events(request)) }
    await answerWaits(1, of: clock)

    #expect(data(try await reader.value) == ["a"])
    #expect(try lastEventIDs(transport) == [nil, "9"])
  }

  @Test("an empty id field clears the id, so the next reconnect carries none")
  func anEmptyIDClearsTheID() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [
      answer("id: 1\ndata: a\n\nid\ndata: b\n\n"), answer("data: c\n\n"),
    ])
    let client = makeClient(clock: clock, transport: transport)

    let reader = Task { try await collect(3, from: client.events(request)) }
    await answerWaits(1, of: clock)

    #expect(data(try await reader.value) == ["a", "b", "c"])
    #expect(try lastEventIDs(transport) == [nil, nil])
  }

  @Test("an id set on one connection is still sent after a connection that set none")
  func anIDSurvivesAConnectionThatSetNone() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [
      answer("id: 1\ndata: a\n\n"), answer("data: b\n\n"), answer("data: c\n\n"),
    ])
    let client = makeClient(clock: clock, transport: transport)

    let reader = Task { try await collect(3, from: client.events(request)) }
    await answerWaits(2, of: clock)

    #expect(data(try await reader.value) == ["a", "b", "c"])
    #expect(try lastEventIDs(transport) == [nil, "1", "1"])
  }

  @Test("after a reconnect, an event without an id field of its own reports the remembered id")
  func anEventAfterAReconnectReportsTheRememberedID() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [
      answer("id: 1\ndata: a\n\n"), answer("data: b\n\nid: 2\ndata: c\n\n"),
    ])
    let client = makeClient(clock: clock, transport: transport)

    let reader = Task { try await collect(3, from: client.events(request)) }
    await answerWaits(1, of: clock)

    #expect(try await reader.value.map(\.id) == ["1", "1", "2"])
  }

  @Test("a status outside 2xx ends the sequence with that failure and no reconnect")
  func aFailedStatusEndsTheSequence() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [answer("forbidden", status: .forbidden)])
    let client = makeClient(clock: clock, transport: transport)

    let error = try #require(
      await failure(of: { try await collect(1, from: client.events(request)) }))

    guard case .httpStatus(let body, let code, _) = error else {
      Issue.record("expected httpStatus, got \(error)")
      return
    }
    #expect(code == 403)
    #expect(body == Data("forbidden".utf8))
    #expect(transport.requests.count == 1)
    #expect(clock.sleeps == [])
  }

  @Test("a 204 ends the sequence cleanly")
  func aNoContentEndsTheSequenceCleanly() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [answer("", status: .noContent)])
    let client = makeClient(clock: clock, transport: transport)

    let events = try await collect(1, from: client.events(request))

    #expect(events == [])
    #expect(transport.requests.count == 1)
    #expect(clock.sleeps == [])
  }

  @Test("a line that is not valid UTF-8 ends the sequence with a decode failure")
  func anInvalidLineEndsTheSequence() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [
      .success(
        MockTransport.Answer(chunks: [Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0xFF, 0x0A, 0x0A])]))
    ])
    let client = makeClient(clock: clock, transport: transport)

    let error = try #require(
      await failure(of: { try await collect(1, from: client.events(request)) }))

    guard case .decode = error else {
      Issue.record("expected decode, got \(error)")
      return
    }
    #expect(transport.requests.count == 1)
    #expect(clock.sleeps == [])
  }

  @Test("a line past maxLineLength ends the sequence rather than reconnecting")
  func aLineTooLongEndsTheSequence() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [answer("data: a line past the limit\n\n")])
    let client = makeClient(clock: clock, transport: transport)

    let error = try #require(
      await failure(of: { try await collect(1, from: client.events(request, maxLineLength: 8)) }))

    #expect(error.underlying as? LineSplitterFailure == .lineTooLong(limit: 8))
    #expect(transport.requests.count == 1)
    #expect(clock.sleeps == [])
  }

  @Test("a consumer cancelled while waiting to reconnect leaves with cancelled and sends no more")
  func aConsumerCancelledWhileWaitingLeavesWithCancelled() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [answer("data: a\n\n"), answer("data: b\n\n")])
    let client = makeClient(clock: clock, transport: transport)

    let reader = Task { await failure(of: { try await collect(2, from: client.events(request)) }) }
    await clock.waitForPendingSleep()
    reader.cancel()

    #expect(isCancelled(try #require(await reader.value)))
    #expect(transport.requests.count == 1)
    #expect(clock.pendingSleeps == 0)
  }

  @Test("a consumer cancelled while parked on a body leaves with cancelled")
  func aConsumerCancelledOnABodyLeavesWithCancelled() async throws {
    // `AsyncStream` finishes as soon as its continuation is released, so the test holds the
    // continuation for as long as the body must stay parked.
    let (body, continuation) = AsyncStream<Data>.makeStream()
    defer { continuation.finish() }
    let clock = RecordingClock()
    let transport = MockTransport(answers: [
      .success(MockTransport.Answer(body: { StreamedBody(body) }))
    ])
    let client = makeClient(clock: clock, transport: transport)

    // `Task.immediate` runs to the first suspension synchronously, so the consumer is parked on the
    // body before `cancel()` arrives.
    let reader = Task.immediate {
      await failure(of: { try await collect(1, from: client.events(request)) })
    }
    reader.cancel()

    #expect(isCancelled(try #require(await reader.value)))
    #expect(transport.requests.count == 1)
    #expect(clock.sleeps == [])
  }

  @Test("a cancelled consumer whose connect fails with a transport failure does not reconnect")
  func aCancelledConsumerDoesNotReconnectAfterATransportFailure() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [.failure(connectivity), answer("data: a\n\n")])
    let client = makeClient(clock: clock, transport: transport)

    // A task added to an already-cancelled group starts cancelled, and the mock transport checks
    // no cancellation of its own, so the connect fails as seeded on a task that is cancelled.
    let outcome = await withTaskGroup(of: TransportError?.self) { group in
      group.cancelAll()
      group.addTask {
        await failure(of: { try await collect(1, from: client.events(request)) })
      }
      return await group.next() ?? nil
    }

    #expect(isCancelled(try #require(outcome)))
    #expect(transport.requests.count == 1)
    #expect(clock.sleeps == [])
  }

  @Test("a cancelled consumer whose connect fails with a status leaves with cancelled")
  func aCancelledConsumerLeavesWithCancelledAfterAStatusFailure() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [answer("", status: .forbidden)])
    let client = makeClient(clock: clock, transport: transport)

    let outcome = await withTaskGroup(of: TransportError?.self) { group in
      group.cancelAll()
      group.addTask {
        await failure(of: { try await collect(1, from: client.events(request)) })
      }
      return await group.next() ?? nil
    }

    #expect(isCancelled(try #require(outcome)))
    #expect(transport.requests.count == 1)
  }

  @Test("eight iterators over one value each make their own connections and reconnect on their own")
  func eightIteratorsReconnectIndependently() async throws {
    let clock = RecordingClock()
    let transport = MockTransport()
    transport.setHandler(forPath: path) { _ in
      .success(MockTransport.Answer(chunks: [Data("id: 1\ndata: a\n\n".utf8)]))
    }
    let client = makeClient(clock: clock, transport: transport)
    let events = client.events(request)

    let readers = (0..<8).map { _ in Task { try await collect(2, from: events) } }
    await clock.waitForPendingSleep(count: 8)
    clock.advanceAll()

    for reader in readers {
      #expect(data(try await reader.value) == ["a", "a"])
    }
    #expect(transport.requests.count == 16)
    #expect(try lastEventIDs(transport).filter { $0 == "1" }.count == 8)
    #expect(clock.sleeps == Array(repeating: .seconds(3), count: 8))
  }

  @Test(
    "the sequence erases to some AsyncSequence<ServerSentEvent, TransportError> and is Sendable")
  func theSequenceErasesAndIsSendable() async throws {
    let clock = RecordingClock()
    let transport = MockTransport(answers: [answer("data: a\n\n")])
    let client = makeClient(clock: clock, transport: transport)

    let events: some AsyncSequence<ServerSentEvent, TransportError> & Sendable =
      client.events(request)

    var iterator = events.makeAsyncIterator()
    #expect(try await iterator.next()?.data == "a")
  }
}
