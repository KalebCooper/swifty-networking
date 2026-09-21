#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTesting
import Testing
import WebSocketCore
import WebSocketTestSupport

@Suite("WebSocket lifecycle", .timeLimit(.minutes(suiteTimeLimitMinutes)))
@MainActor
struct WebSocketLifecycleTests {
  private enum ApplicationFailure: Error { case expected }

  private struct LifetimeTransport: WebSocketTransport {
    let released: WebSocketRendezvous
    let script: ScriptedWebSocketConnection

    func connect(_ request: WebSocketRequest, options: WebSocket.Options)
      async throws(WebSocketError) -> TrackedConnection
    {
      TrackedConnection(released: released, script: script)
    }
  }

  private final class TrackedConnection: WebSocketConnection {
    let released: WebSocketRendezvous
    let script: ScriptedWebSocketConnection

    init(released: WebSocketRendezvous, script: ScriptedWebSocketConnection) {
      self.released = released
      self.script = script
    }

    deinit { released.release() }

    var closeInfo: WebSocketClose? { script.closeInfo }
    var negotiatedSubprotocol: String? { script.negotiatedSubprotocol }

    func cancel() { script.cancel() }
    func close(code: WebSocket.CloseCode, reason: String?)
      async throws(WebSocketError) -> WebSocketClose
    {
      try await script.close(code: code, reason: reason)
    }
    func ping() async throws(WebSocketError) { try await script.ping() }
    func receive() async throws(WebSocketError) -> WebSocket.Message? { try await script.receive() }
    func send(_ message: WebSocket.Message) async throws(WebSocketError) {
      try await script.send(message)
    }
  }

  private final class Value {
    var socket: WebSocket?
    var text = "result"
  }

  @Test("Cancelling a ping caller preserves the outstanding probe and its deadline")
  func cancelledPingKeepsDeadline() async throws {
    let clock = RecordingClock()
    let receive = WebSocketRendezvous()
    let pong = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: receive, result: .success(.message(nil))),
      .init(gate: pong, result: .success(.completed)),
    ])
    let socket = try await client(backend, clock: clock).connect(to: url())
    defer { socket.cancel() }
    try await receive.waitForArrival()
    let caller = Task { try await socket.ping() }
    try await pong.waitForArrival()
    await clock.waitForPendingSleep()
    caller.cancel()
    await #expect(throws: WebSocketError.self) { try await caller.value }
    #expect(!backend.operations.contains(.cancel))
    await #expect { try await socket.ping() } throws: {
      ($0 as? WebSocketError)?.kind == .concurrentOperation
    }
    clock.advance(by: .seconds(10))
    try await backend.waitForCancellation()
    var iterator = socket.messages.makeAsyncIterator()
    await #expect { try await iterator.next() } throws: {
      ($0 as? WebSocketError)?.kind == .timedOut
    }
  }

  @Test("Cancelling a reader preserves the next message for a new iterator")
  func cancelledReaderPreservesMessage() async throws {
    let first = WebSocketRendezvous()
    let second = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(result: .success(.message(.text("claim")))),
      .init(gate: first, result: .success(.message(.text("next")))),
      .init(gate: second, result: .success(.message(nil))),
    ])
    let socket = try await client(backend).connect(to: url())
    defer { socket.cancel() }
    try await first.waitForArrival()
    var reader = socket.messages.makeAsyncIterator()
    #expect(try await reader.next() == .text("claim"))
    let claimed = reader
    let rejected = WebSocketRendezvous()
    let contenders = (0..<2).map { _ in
      Task { @MainActor in
        var copy = claimed
        do throws(WebSocketError) {
          _ = try await copy.next()
          Issue.record("The physical receive is still gated")
          return WebSocketError.Kind.closed
        } catch {
          if error.kind == .concurrentOperation { rejected.arrive() }
          return error.kind
        }
      }
    }
    try await rejected.waitForArrival()
    for contender in contenders { contender.cancel() }
    var failures: [WebSocketError.Kind] = []
    for contender in contenders { failures.append(await contender.value) }
    #expect(failures.filter { $0 == .cancelled }.count == 1)
    #expect(failures.filter { $0 == .concurrentOperation }.count == 1)
    first.release()
    try await second.waitForArrival()
    var replacement = socket.messages.makeAsyncIterator()
    #expect(try await replacement.next() == .text("next"))
    #expect(!backend.operations.contains(.cancel))
  }

  @Test("Competing readers fail without consuming the owning reader's messages")
  func competingReadersPreserveOwner() async throws {
    let parked = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(result: .success(.message(.text("a")))),
      .init(result: .success(.message(.text("b")))),
      .init(gate: parked, result: .success(.message(nil))),
    ])
    let socket = try await client(backend).connect(to: url())
    defer { socket.cancel() }
    try await parked.waitForArrival()
    var owner = socket.messages.makeAsyncIterator()
    var competitor = socket.messages.makeAsyncIterator()
    #expect(try await owner.next() == .text("a"))
    await #expect { try await competitor.next() } throws: {
      ($0 as? WebSocketError)?.kind == .concurrentOperation
    }
    #expect(try await owner.next() == .text("b"))
    #expect(!backend.operations.contains(.cancel))
  }

  @Test(
    "Receive delivery racing cancellation neither loses nor duplicates the message",
    arguments: 0..<8)
  func deliveryRacingCancellationPreservesMessage(_ iteration: Int) async throws {
    let message = WebSocket.Message.text(String(iteration))
    let receive = WebSocketRendezvous()
    let tail = WebSocketRendezvous()
    let race = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: receive, result: .success(.message(message))),
      .init(gate: tail, result: .success(.message(nil))),
    ])
    let socket = try await client(backend).connect(to: url())
    defer { socket.cancel() }
    try await receive.waitForArrival()
    let read = Task { @MainActor () -> Result<WebSocket.Message?, WebSocketError> in
      var iterator = socket.messages.makeAsyncIterator()
      do throws(WebSocketError) { return .success(try await iterator.next()) } catch {
        return .failure(error)
      }
    }
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        try? await race.arriveAndWait(); read.cancel()
      }
      group.addTask {
        try? await race.arriveAndWait(); receive.release()
      }
      try? await race.waitForArrival(count: 2)
      race.release()
    }
    let result = await read.value
    try await tail.waitForArrival()
    switch result {
    case .success(let received): #expect(received == message)
    case .failure(let error):
      #expect(error.kind == .cancelled)
      var replacement = socket.messages.makeAsyncIterator()
      #expect(try await replacement.next() == message)
    }
    #expect(!backend.operations.contains(.cancel))
  }

  @Test("Dropping the last iterator copy releases its claim without aborting a retained socket")
  func droppedIteratorReleasesClaim() async throws {
    let parked = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(result: .success(.message(.text("a")))),
      .init(result: .success(.message(.text("b")))),
      .init(gate: parked, result: .success(.message(nil))),
    ])
    let socket = try await client(backend).connect(to: url())
    defer { socket.cancel() }
    try await parked.waitForArrival()
    var first: WebSocketMessages.Iterator? = socket.messages.makeAsyncIterator()
    #expect(try await first?.next() == .text("a"))
    var copy = first
    first = nil
    var replacement = socket.messages.makeAsyncIterator()
    await #expect { try await replacement.next() } throws: {
      ($0 as? WebSocketError)?.kind == .concurrentOperation
    }
    #expect(copy != nil)
    copy = nil
    #expect(try await replacement.next() == .text("b"))
    #expect(!backend.operations.contains(.cancel))
  }

  @Test("An empty close remains empty and maximum integer capacities do not overflow")
  func emptyCloseAndMaximumCapacities() async throws {
    let backend = ScriptedWebSocketConnection(
      closeInfo: .init(),
      steps: [
        .init(result: .success(.message(.text("")))),
        .init(result: .success(.message(.text("x")))),
        .init(result: .success(.message(nil))),
      ])
    let socket = try await client(backend).connect(
      to: url(),
      options: .init(
        maxBufferedBytes: .max, maxBufferedMessages: .max, maxMessageBytes: .max,
        maxPendingSendBytes: .max, maxPendingSendMessages: .max))
    try await backend.waitForCancellation()
    var reader = socket.messages.makeAsyncIterator()
    #expect(try await reader.next() == .text(""))
    #expect(try await reader.next() == .text("x"))
    #expect(try await reader.next() == nil)
    #expect(socket.closeInfo == .init())
  }

  @Test("Failed setup never invokes a scoped operation")
  func failedSetupSkipsOperation() async throws {
    let transport = MockWebSocketTransport(answers: [
      .init(result: .failure(WebSocketError(kind: .handshakeRejected)))
    ])
    let value = Value()
    await #expect {
      try await WebSocketClient(transport: transport).withConnection(to: url()) { socket in
        value.socket = socket
      }
    } throws: { ($0 as? WebSocketError)?.kind == .handshakeRejected }
    #expect(value.socket == nil)
    #expect(transport.calls.count == 1)
  }

  @Test("A backend receive failure discards buffered messages and remains authoritative")
  func failureDiscardsInbox() async throws {
    let failure = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(result: .success(.message(.text("unread")))),
      .init(gate: failure, result: .failure(WebSocketError(kind: .transport))),
    ])
    let socket = try await client(backend).connect(to: url())
    try await failure.waitForArrival()
    failure.release()
    try await backend.waitForCancellation()
    socket.cancel()
    var reader = socket.messages.makeAsyncIterator()
    await #expect { try await reader.next() } throws: {
      ($0 as? WebSocketError)?.kind == .transport
    }
    #expect(backend.operations.filter { $0 == .cancel }.count == 1)
  }

  @Test("The last external owner releases backend state and every registered timer")
  func internalTasksDoNotRetainConnection() async throws {
    let clock = WebSocketCompletionClock()
    let parked = WebSocketRendezvous()
    let pong = WebSocketRendezvous()
    let released = WebSocketRendezvous()
    let script = ScriptedWebSocketConnection(steps: [
      .init(gate: parked, result: .success(.message(nil))),
      .init(gate: pong, result: .success(.completed)),
    ])
    let transport = LifetimeTransport(released: released, script: script)
    var socket: WebSocket? = try await WebSocketClient(clock: clock, transport: transport).connect(
      to: url())
    try await parked.waitForArrival()
    try await clock.completed.waitForArrival()
    var caller: Task<Void, any Error>? = Task { [socket] in try await socket?.ping() }
    try await pong.waitForArrival()
    await clock.underlying.waitForPendingSleep()
    caller?.cancel()
    _ = await caller?.result
    caller = nil
    socket = nil
    try await released.arriveAndWait()
    try await clock.completed.waitForArrival(count: 2)
    #expect(clock.underlying.pendingSleeps == 0)
    #expect(script.operations.filter { $0 == .cancel }.count == 1)
  }

  @Test(
    "Invalid options fail before transport work",
    arguments: [
      WebSocket.Options(closeTimeout: .zero),
      WebSocket.Options(connectTimeout: .zero),
      WebSocket.Options(maxBufferedBytes: 0),
      WebSocket.Options(maxBufferedMessages: 0),
      WebSocket.Options(maxMessageBytes: 0),
      WebSocket.Options(maxPendingSendBytes: -1),
      WebSocket.Options(maxPendingSendMessages: 0),
      WebSocket.Options(pingTimeout: .seconds(-1)),
    ])
  func invalidOptionsStartNoTransport(_ options: WebSocket.Options) async throws {
    let transport = MockWebSocketTransport()
    await #expect {
      try await WebSocketClient(transport: transport).connect(to: url(), options: options)
    } throws: {
      ($0 as? WebSocketError)?.kind == .invalidRequest
    }
    #expect(transport.calls.isEmpty)
  }

  @Test("Messages and iterator owners keep one pump alive until the final owner is dropped")
  func lastOwnerAbortsPendingReceive() async throws {
    let parked = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: parked, result: .success(.message(nil)))
    ])
    var socket: WebSocket? = try await client(backend).connect(to: url())
    try await parked.waitForArrival()
    var messages = socket?.messages
    var iterator = messages?.makeAsyncIterator()
    socket = nil
    messages = nil
    #expect(!backend.operations.contains(.cancel))
    #expect(iterator != nil)
    iterator = nil
    #expect(backend.operations == [.receive, .cancel])
  }

  @Test("A late pong frees a cancelled caller's slot without extending the next probe's deadline")
  func latePongFreesSlot() async throws {
    let clock = WebSocketCompletionClock()
    let receive = WebSocketRendezvous()
    let pong = WebSocketRendezvous()
    let nextPong = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: receive, result: .success(.message(nil))),
      .init(gate: pong, result: .success(.completed)),
      .init(gate: nextPong, result: .success(.completed)),
    ])
    let socket = try await WebSocketClient(
      clock: clock,
      transport: MockWebSocketTransport(answers: [.init(result: .success(backend))])
    ).connect(to: url())
    defer { socket.cancel() }
    try await receive.waitForArrival()
    try await clock.completed.waitForArrival()
    let first = Task { try await socket.ping() }
    try await pong.waitForArrival()
    await clock.underlying.waitForPendingSleep()
    first.cancel()
    await #expect(throws: WebSocketError.self) { try await first.value }
    pong.release()
    try await clock.completed.waitForArrival(count: 2)
    #expect(clock.underlying.pendingSleeps == 0)
    let next = Task { try await socket.ping() }
    try await nextPong.waitForArrival()
    await clock.underlying.waitForPendingSleep()
    clock.underlying.advance(by: .seconds(10))
    await #expect { try await next.value } throws: {
      ($0 as? WebSocketError)?.kind == .timedOut
    }
    try await backend.waitForCancellation()
  }

  @Test("A receive end without close metadata fails without fabricating a close code")
  func missingCloseMetadataFails() async throws {
    let backend = ScriptedWebSocketConnection(steps: [.init(result: .success(.message(nil)))])
    let socket = try await client(backend).connect(to: url())
    try await backend.waitForCancellation()
    var reader = socket.messages.makeAsyncIterator()
    await #expect { try await reader.next() } throws: {
      ($0 as? WebSocketError)?.kind == .protocolViolation
    }
    #expect(socket.closeInfo == nil)
  }

  @Test("Normal peer close drains exact byte and count capacity and preserves private metadata")
  func normalCloseDrainsInbox() async throws {
    let ended = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(
      closeInfo: .init(code: .init(rawValue: 4001), reason: "done"),
      negotiatedSubprotocol: "chat",
      steps: [
        .init(result: .success(.message(.text("é")))),
        .init(result: .success(.message(.binary(Data([1, 2]))))),
        .init(gate: ended, result: .success(.message(nil))),
      ])
    let socket = try await client(backend).connect(
      to: url(), options: .init(maxBufferedBytes: 4, maxBufferedMessages: 2, maxMessageBytes: 4))
    try await ended.waitForArrival()
    ended.release()
    try await backend.waitForCancellation()
    var iterator = socket.messages.makeAsyncIterator()
    #expect(try await iterator.next() == .text("é"))
    #expect(try await iterator.next() == .binary(Data([1, 2])))
    #expect(try await iterator.next() == nil)
    #expect(socket.closeInfo == .init(code: .init(rawValue: 4001), reason: "done"))
    #expect(socket.negotiatedSubprotocol == "chat")
  }

  @Test(
    "Inbox overflow is terminal and its close attempt ends at the configured deadline",
    arguments: [false, true])
  func overflowIsBounded(empty: Bool) async throws {
    let clock = RecordingClock()
    let close = WebSocketRendezvous()
    let message: WebSocket.Message = .text(empty ? "" : "é")
    let backend = ScriptedWebSocketConnection(steps: [
      .init(result: .success(.message(message))),
      .init(result: .success(.message(message))),
      .init(gate: close, result: .success(.close(.init()))),
    ])
    let socket = try await client(backend, clock: clock).connect(
      to: url(),
      options: .init(
        closeTimeout: .seconds(3), maxBufferedBytes: 2,
        maxBufferedMessages: empty ? 1 : 2, maxMessageBytes: 2))
    try await close.waitForArrival()
    var iterator = socket.messages.makeAsyncIterator()
    await #expect { try await iterator.next() } throws: {
      ($0 as? WebSocketError)?.kind == .bufferOverflow
    }
    #expect(backend.operations.contains(.close(code: .init(rawValue: 1008), reason: nil)))
    #expect(!backend.operations.contains(.cancel))
    await clock.waitForPendingSleep()
    clock.advance(by: .seconds(3))
    try await backend.waitForCancellation()
    #expect(backend.operations.filter { $0 == .cancel }.count == 1)
  }

  @Test("Overlapping next calls through iterator copies have exactly one winner")
  func overlappingIteratorCopies() async throws {
    let parked = WebSocketRendezvous()
    let tail = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: parked, result: .success(.message(.text("winner")))),
      .init(gate: tail, result: .success(.message(nil))),
    ])
    let socket = try await client(backend).connect(to: url())
    defer { socket.cancel() }
    try await parked.waitForArrival()
    let original = socket.messages.makeAsyncIterator()
    let rejected = WebSocketRendezvous()
    let tasks = (0..<8).map { _ in
      Task { @MainActor in
        var copy = original
        do throws(WebSocketError) {
          let message = try await copy.next()
          return message == .text("winner")
        } catch {
          #expect(error.kind == .concurrentOperation)
          try? await rejected.arriveAndWait()
          return false
        }
      }
    }
    try await rejected.waitForArrival(count: 7)
    parked.release()
    rejected.release()
    var winners = 0
    for task in tasks { if await task.value { winners += 1 } }
    #expect(winners == 1)
  }

  @Test("An oversized UTF-8 message fails and closes with code 1009")
  func oversizedMessageFails() async throws {
    let closing = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(result: .success(.message(.text("€")))),
      .init(gate: closing, result: .success(.close(.init()))),
    ])
    let socket = try await client(backend).connect(
      to: url(), options: .init(maxBufferedBytes: 2, maxMessageBytes: 2))
    try await closing.waitForArrival()
    var iterator = socket.messages.makeAsyncIterator()
    await #expect { try await iterator.next() } throws: {
      ($0 as? WebSocketError)?.kind == .messageTooLarge
    }
    #expect(backend.operations.contains(.close(code: .init(rawValue: 1009), reason: nil)))
    closing.release()
    try await backend.waitForCancellation()
  }

  @Test("A pong completes one ping and releases its slot for the next ping")
  func pongReleasesProbe() async throws {
    let receive = WebSocketRendezvous()
    let pong = WebSocketRendezvous()
    let second = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: receive, result: .success(.message(nil))),
      .init(gate: pong, result: .success(.completed)),
      .init(gate: second, result: .success(.completed)),
    ])
    let socket = try await client(backend).connect(to: url())
    defer { socket.cancel() }
    try await receive.waitForArrival()
    let first = Task { try await socket.ping() }
    try await pong.waitForArrival()
    pong.release()
    try await first.value
    let next = Task { try await socket.ping() }
    try await second.waitForArrival()
    second.release()
    try await next.value
    #expect(!backend.operations.contains(.cancel))
  }

  @Test("Cancelling before ping admission performs no ping and keeps the socket healthy")
  func preCancelledPingHasNoEffect() async throws {
    let parked = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: parked, result: .success(.message(nil)))
    ])
    let socket = try await client(backend).connect(to: url())
    defer { socket.cancel() }
    try await parked.waitForArrival()
    let entry = WebSocketRendezvous()
    let task = Task {
      try? await entry.arriveAndWait()
      try await socket.ping()
    }
    try await entry.waitForArrival()
    task.cancel()
    await #expect { try await task.value } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
    #expect(backend.operations == [.receive])
  }

  @Test("Cancelling a scope aborts while its operation is suspended")
  func scopeCancellationAborts() async throws {
    let operation = WebSocketRendezvous()
    let receive = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: receive, result: .success(.message(nil)))
    ])
    let task = Task {
      try await client(backend).withConnection(to: url()) { _ in
        try await operation.arriveAndWait()
      }
    }
    try await operation.waitForArrival()
    task.cancel()
    try await backend.waitForCancellation()
    await #expect(throws: WebSocketError.self) { try await task.value }
    #expect(backend.operations.filter { $0 == .cancel }.count == 1)
  }

  @Test("Scoped connections preserve application errors and terminate escaped handles")
  func scopePreservesErrors() async throws {
    let parked = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: parked, result: .success(.message(nil)))
    ])
    let value = Value()
    await #expect(throws: ApplicationFailure.expected) {
      try await client(backend).withConnection(to: url()) { socket in
        value.socket = socket
        try await parked.waitForArrival()
        throw ApplicationFailure.expected
      }
    }
    #expect(backend.operations.contains(.cancel))
    await #expect { try await value.socket?.ping() } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
  }

  @Test("Scoped connections return a non-Sendable caller-isolated result and clean up")
  func scopeReturnsNonSendableResult() async throws {
    let parked = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: parked, result: .success(.message(nil)))
    ])
    let value = Value()
    let returned = try await client(backend).withConnection(to: url()) { socket in
      value.socket = socket
      try await parked.waitForArrival()
      return value
    }
    #expect(returned === value)
    #expect(returned.text == "result")
    #expect(backend.operations.contains(.cancel))
  }

  @Test("Concurrent terminal contenders settle pending work once and abort exactly once")
  func terminalContentionSettlesOnce() async throws {
    let clock = RecordingClock()
    let receive = WebSocketRendezvous()
    let pong = WebSocketRendezvous()
    let race = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: receive, result: .success(.message(nil))),
      .init(gate: pong, result: .success(.completed)),
    ])
    let socket = try await client(backend, clock: clock).connect(to: url())
    try await receive.waitForArrival()
    let ping = Task { try await socket.ping() }
    try await pong.waitForArrival()
    await clock.waitForPendingSleep()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          try? await race.arriveAndWait()
          socket.cancel()
        }
      }
      group.addTask {
        try? await race.arriveAndWait()
        clock.advance(by: .seconds(10))
      }
      try? await race.waitForArrival(count: 9)
      race.release()
    }
    await #expect { try await ping.value } throws: {
      guard let error = $0 as? WebSocketError else { return false }
      return error.kind == .cancelled || error.kind == .timedOut
    }
    var reader = socket.messages.makeAsyncIterator()
    await #expect { try await reader.next() } throws: {
      guard let error = $0 as? WebSocketError else { return false }
      return error.kind == .cancelled || error.kind == .timedOut
    }
    #expect(try await reader.next() == nil)
    #expect(backend.operations.filter { $0 == .cancel }.count == 1)
  }

  @Test("URL and request conveniences pass identical inputs and capture options")
  func urlAndRequestShareExecution() async throws {
    let parked = WebSocketRendezvous()
    let one = ScriptedWebSocketConnection(steps: [
      .init(gate: parked, result: .success(.message(nil)))
    ])
    let two = ScriptedWebSocketConnection(steps: [
      .init(gate: parked, result: .success(.message(nil)))
    ])
    let transport = MockWebSocketTransport(answers: [
      .init(result: .success(one)), .init(result: .success(two)),
    ])
    let client = WebSocketClient(transport: transport)
    let first = try await client.connect(to: url())
    let second = try await client.connect(WebSocketRequest(url: url()))
    defer { first.cancel(); second.cancel() }
    #expect(transport.calls.count == 2)
    #expect(transport.calls[0].request.url == transport.calls[1].request.url)
    #expect(transport.calls[0].options == transport.calls[1].options)
    #expect(transport.calls[0].options.closeTimeout == .seconds(5))
    #expect(transport.calls[0].options.connectTimeout == .seconds(30))
    #expect(transport.calls[0].options.pingTimeout == .seconds(10))
  }

  private func client(
    _ backend: ScriptedWebSocketConnection, clock: RecordingClock = RecordingClock()
  ) -> WebSocketClient {
    WebSocketClient(
      clock: clock,
      transport: MockWebSocketTransport(answers: [
        .init(result: .success(backend))
      ]))
  }

  private func url() throws -> URL { try #require(URL(string: "wss://example.com/socket")) }
}
