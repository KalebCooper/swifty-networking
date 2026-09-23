#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Darwin)
import Foundation
#endif

import HTTPTesting
import Testing
import WebSocketCore

@Suite("WebSocket send settlement", .timeLimit(.minutes(suiteTimeLimitMinutes)))
@MainActor
struct WebSocketSendSettlementTests {
  private final class LateConnection: WebSocketConnection {
    let finished = WebSocketRendezvous()
    let gate: WebSocketRendezvous
    let script: ScriptedWebSocketConnection

    init(gate: WebSocketRendezvous, script: ScriptedWebSocketConnection) {
      self.gate = gate
      self.script = script
    }

    var closeInfo: WebSocketClose? { script.closeInfo }
    var negotiatedSubprotocol: String? { nil }

    func cancel() { script.cancel() }
    func close(code: WebSocket.CloseCode, reason: String?) async throws(WebSocketError)
      -> WebSocketClose
    {
      try await script.close(code: code, reason: reason)
    }
    func ping() async throws(WebSocketError) { try await script.ping() }
    func receive() async throws(WebSocketError) -> WebSocket.Message? { try await script.receive() }
    func send(_ message: WebSocket.Message) async throws(WebSocketError) {
      // Record the call without retaining its payload in the script.
      try await script.send(.text("recorded"))
      // An unstructured task does not inherit this send's cancellation, so the backend models a
      // result that arrives late; each test's deferred release frees the waiter.
      await Task { try? await gate.arriveAndWait() }.value
      finished.arrive()
    }
  }

  private struct LateTransport: WebSocketTransport {
    let backend: LateConnection

    func connect(_ request: WebSocketRequest, options: WebSocket.Options)
      async throws(WebSocketError) -> LateConnection
    {
      backend
    }
  }

  @Test("Async overloads inherit and override both defaults without changing message bytes")
  func asyncOverloadsSharePolicies() async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(sendFailurePolicy: .abortConnection, sendPolicy: .rejectOverlapping),
      steps: [.init(gate: held, result: .success(.completed))]
        + Array(repeating: .init(result: .success(.completed)), count: 3))
    defer { fixture.socket.cancel() }
    let first = try fixture.socket.enqueue("first")
    try await held.waitForArrival()
    await #expect {
      try await fixture.socket.send(Data([9]), failurePolicy: .preserveIfUnsent)
    } throws: { ($0 as? WebSocketError)?.kind == .concurrentOperation }
    let binary = Task.immediate { @MainActor in
      try await fixture.socket.send(Data([1, 2]), policy: .serialize)
    }
    let text = Task.immediate { @MainActor in
      try await fixture.socket.send("é", policy: .serialize)
    }
    let message = Task.immediate { @MainActor in
      try await fixture.socket.send(.binary(Data([3])), policy: .serialize)
    }
    held.release()
    try await first.wait()
    try await binary.value
    try await text.value
    try await message.value
    #expect(
      fixture.sent == [.text("first"), .binary(Data([1, 2])), .text("é"), .binary(Data([3]))])
  }

  @Test("Independent connection limits and maximum integer budgets retain their own boundaries")
  func connectionLimitsAreIndependent() async throws {
    let held = WebSocketRendezvous()
    let small = try await SendFixture.open(
      options: .init(maxPendingSendMessages: 1),
      steps: [.init(gate: held, result: .success(.completed))])
    let large = try await SendFixture.open(
      options: .init(maxPendingSendBytes: .max, maxPendingSendMessages: .max),
      steps: [.init(gate: held, result: .success(.completed)), .init(result: .success(.completed))])
    defer { small.socket.cancel(); large.socket.cancel() }
    let one = try small.socket.enqueue("")
    let two = try large.socket.enqueue("a")
    try await held.waitForArrival(count: 2)
    #expect { try small.socket.enqueue("") } throws: {
      ($0 as? WebSocketError)?.kind == .sendQueueFull
    }
    let three = try large.socket.enqueue("b")
    held.release()
    for operation in [one, two, three] { try await operation.wait() }
    #expect(small.sent == [.text("")])
    #expect(large.sent == [.text("a"), .text("b")])
  }

  @Test(
    "A delayed deadline racing dequeue removes an unstarted send or aborts an active one",
    arguments: 0..<4)
  func deadlineRacesDequeue(_ iteration: Int) async throws {
    let firstGate = WebSocketRendezvous()
    let secondGate = WebSocketRendezvous()
    let race = WebSocketRendezvous()
    let fixture = try await SendFixture.open(steps: [
      .init(gate: firstGate, result: .success(.completed)),
      .init(gate: secondGate, result: .success(.completed)),
    ])
    defer { fixture.socket.cancel() }
    let first = try fixture.socket.enqueue("first")
    try await firstGate.waitForArrival()
    let second = try fixture.socket.enqueue("second")
    await fixture.clock.underlying.waitForPendingSleep()
    async let advance: Void = {
      try? await race.arriveAndWait()
      fixture.clock.underlying.advance(by: .seconds(30))
    }()
    async let finish: Void = {
      try? await race.arriveAndWait()
      firstGate.release()
    }()
    try await race.waitForArrival(count: 2)
    race.release()
    _ = await (advance, finish)
    do { try await first.wait() } catch { #expect(error.kind == .timedOut) }
    await #expect { try await second.wait() } throws: { ($0 as? WebSocketError)?.kind == .timedOut }
    if fixture.sent.contains(.text("second")) {
      #expect(fixture.backend.operations.contains(.cancel))
    }
    #expect(fixture.sent.count <= 2)
  }

  @Test("Dropping a send operation leaves its admitted write running")
  func droppedOperationDoesNotCancel() async throws {
    let held = WebSocketRendezvous()
    let tail = WebSocketRendezvous()
    let fixture = try await SendFixture.open(steps: [
      .init(gate: held, result: .success(.completed)),
      .init(gate: tail, result: .success(.completed)),
    ])
    defer { fixture.socket.cancel() }
    _ = try fixture.socket.enqueue("unobserved")
    try await held.waitForArrival()
    let last = try fixture.socket.enqueue("observed")
    held.release()
    try await tail.waitForArrival()
    #expect(!fixture.backend.operations.contains(.cancel))
    tail.release()
    try await last.wait()
    #expect(fixture.sent == [.text("unobserved"), .text("observed")])
  }

  @Test(
    "A late backend success cannot replace cancellation or start a later send",
    arguments: [WebSocket.SendPolicy.rejectOverlapping, .serialize])
  func lateSuccessCannotResurrectSend(_ policy: WebSocket.SendPolicy) async throws {
    let gate = WebSocketRendezvous()
    let receive = WebSocketRendezvous()
    let script = ScriptedWebSocketConnection(steps: [
      .init(gate: receive, result: .success(.message(nil))),
      .init(result: .success(.completed)),
    ])
    let backend = LateConnection(gate: gate, script: script)
    let socket = try await WebSocketClient(
      clock: RecordingClock(), transport: LateTransport(backend: backend)
    ).connect(to: #require(URL(string: "wss://example.com")), options: .init(sendPolicy: policy))
    defer { gate.release(); socket.cancel() }
    try await receive.waitForArrival()
    let first = try socket.enqueue("first")
    try await gate.waitForArrival()
    let second = try socket.enqueue("second", policy: .serialize)
    first.cancel()
    await #expect { try await first.wait() } throws: { ($0 as? WebSocketError)?.kind == .cancelled }
    await #expect { try await second.wait() } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
    gate.release()
    try await backend.finished.waitForArrival()
    await #expect { try await first.wait() } throws: { ($0 as? WebSocketError)?.kind == .cancelled }
    #expect(script.operations == [.receive, .send(.text("recorded")), .cancel])
  }

  @Test(
    "Observer cancellation racing completion never changes the cached send result",
    arguments: 0..<4)
  func observerCancellationRacesCompletion(_ iteration: Int) async throws {
    let held = WebSocketRendezvous()
    let race = WebSocketRendezvous()
    let fixture = try await SendFixture.open(steps: [
      .init(gate: held, result: .success(.completed))
    ])
    defer { fixture.socket.cancel() }
    let operation = try fixture.socket.enqueue("value")
    try await held.waitForArrival()
    let waiter = Task.immediate { @MainActor in try await operation.wait() }
    async let cancel: Void = {
      try? await race.arriveAndWait()
      waiter.cancel()
    }()
    async let finish: Void = {
      try? await race.arriveAndWait()
      held.release()
    }()
    try await race.waitForArrival(count: 2)
    race.release()
    _ = await (cancel, finish)
    do { try await waiter.value } catch { #expect((error as? WebSocketError)?.kind == .cancelled) }
    try await operation.wait()
    #expect(!fixture.backend.operations.contains(.cancel))
  }

  @Test("Receive overflow aborts an active write without writing a competing close frame")
  func overflowDoesNotOverlapWrite() async throws {
    let receive = WebSocketRendezvous()
    let write = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: receive, result: .success(.message(.text("too big")))),
      .init(gate: write, result: .success(.completed)),
    ])
    let socket = try await WebSocketClient(
      clock: RecordingClock(),
      transport: MockWebSocketTransport(answers: [.init(result: .success(backend))])
    ).connect(to: #require(URL(string: "wss://example.com")), options: .init(maxMessageBytes: 1))
    try await receive.waitForArrival()
    let send = try socket.enqueue("a")
    try await write.waitForArrival()
    receive.release()
    await #expect { try await send.wait() } throws: {
      ($0 as? WebSocketError)?.kind == .messageTooLarge
    }
    #expect(backend.operations == [.receive, .send(.text("a")), .cancel])
  }

  #if canImport(Darwin)
  @Test("A retained completed operation releases the backing payload")
  func resultDoesNotRetainPayload() async throws {
    let gate = WebSocketRendezvous()
    let receive = WebSocketRendezvous()
    let script = ScriptedWebSocketConnection(steps: [
      .init(gate: receive, result: .success(.message(nil))),
      .init(result: .success(.completed)), .init(result: .success(.completed)),
    ])
    let backend = LateConnection(gate: gate, script: script)
    let socket = try await WebSocketClient(
      clock: RecordingClock(), transport: LateTransport(backend: backend)
    )
    .connect(to: #require(URL(string: "wss://example.com")))
    defer { gate.release(); socket.cancel() }
    try await receive.waitForArrival()
    var native: NSData? = NSData(data: Data(repeating: 7, count: 100_000))
    weak var backing = native
    var data: Data? = Data(referencing: try #require(native))
    native = nil
    #expect(backing != nil)
    let operation = try socket.enqueue(try #require(data))
    data = nil
    try await gate.waitForArrival()
    #expect(backing != nil)
    gate.release()
    // A later write proves the writer has left the first message's scope.
    try await socket.send("barrier")
    #expect(backing == nil)
    try await operation.wait()
    try await operation.wait()
  }
  #endif

  @Test("Scope exit settles escaped send operations")
  func scopeExitSettlesOperations() async throws {
    let receive = WebSocketRendezvous()
    let write = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: receive, result: .success(.message(nil))),
      .init(gate: write, result: .success(.completed)),
    ])
    let operation = try await WebSocketClient(
      clock: RecordingClock(),
      transport: MockWebSocketTransport(answers: [.init(result: .success(backend))])
    ).withConnection(to: #require(URL(string: "wss://example.com"))) { socket in
      try await receive.waitForArrival()
      let operation = try socket.enqueue("first")
      try await write.waitForArrival()
      return operation
    }
    await #expect { try await operation.wait() } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
    #expect(backend.operations.filter { $0 == .cancel }.count == 1)
  }

  @Test("Settled timers leave no sleeps and cannot time out a later send")
  func settledTimersAreRemoved() async throws {
    let firstGate = WebSocketRendezvous()
    let secondGate = WebSocketRendezvous()
    let fixture = try await SendFixture.open(steps: [
      .init(gate: firstGate, result: .success(.completed)),
      .init(gate: secondGate, result: .success(.completed)),
    ])
    defer { fixture.socket.cancel() }
    let first = try fixture.socket.enqueue("first")
    try await firstGate.waitForArrival()
    await fixture.clock.underlying.waitForPendingSleep()
    firstGate.release()
    try await first.wait()
    try await fixture.clock.completed.waitForArrival(count: 2)
    #expect(fixture.clock.underlying.pendingSleeps == 0)
    fixture.clock.underlying.advance(by: .seconds(20))
    let second = try fixture.socket.enqueue("second")
    try await secondGate.waitForArrival()
    await fixture.clock.underlying.waitForPendingSleep()
    fixture.clock.underlying.advance(by: .seconds(10))
    secondGate.release()
    try await second.wait()
    try await fixture.clock.completed.waitForArrival(count: 3)
    #expect(fixture.clock.underlying.pendingSleeps == 0)
    #expect(!fixture.backend.operations.contains(.cancel))
  }
}
