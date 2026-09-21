#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTesting
import Testing
import WebSocketCore

@Suite("WebSocket sends", .timeLimit(.minutes(suiteTimeLimitMinutes)))
@MainActor
struct WebSocketSendTests {
  @Test(
    "Active cancellation aborts under either failure policy",
    arguments: [
      WebSocket.SendFailurePolicy.abortConnection, .preserveIfUnsent,
    ])
  func activeCancellationAborts(_ policy: WebSocket.SendFailurePolicy) async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(steps: [
      .init(gate: held, result: .success(.completed))
    ])
    let first = try fixture.socket.enqueue("a", failurePolicy: policy)
    try await held.waitForArrival()
    let queued = try fixture.socket.enqueue("b")
    first.cancel()
    first.cancel()
    await #expect { try await first.wait() } throws: { ($0 as? WebSocketError)?.kind == .cancelled }
    await #expect { try await queued.wait() } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
    #expect(fixture.sent == [.text("a")])
    #expect(fixture.backend.operations.filter { $0 == .cancel }.count == 1)
  }

  @Test(
    "Admission and failure policy combinations honor defaults and per-send overrides",
    arguments: [WebSocket.SendPolicy.rejectOverlapping, .serialize],
    [WebSocket.SendFailurePolicy.abortConnection, .preserveIfUnsent])
  func admissionPolicyCombinations(
    _ admission: WebSocket.SendPolicy, _ failure: WebSocket.SendFailurePolicy
  ) async throws {
    for overrides in [false, true] {
      let held = WebSocketRendezvous()
      let fixture = try await SendFixture.open(
        options: .init(
          maxPendingSendMessages: 1,
          sendFailurePolicy: overrides
            ? (failure == .abortConnection ? .preserveIfUnsent : .abortConnection) : failure,
          sendPolicy: overrides
            ? (admission == .serialize ? .rejectOverlapping : .serialize) : admission),
        steps: [
          .init(gate: held, result: .success(.completed)), .init(result: .success(.completed)),
        ])
      defer { fixture.socket.cancel() }
      let first = try fixture.socket.enqueue("first")
      try await held.waitForArrival()
      #expect(throws: WebSocketError.self) {
        try fixture.socket.enqueue(
          "rejected", failurePolicy: overrides ? failure : nil, policy: overrides ? admission : nil)
      }
      do {
        _ = try fixture.socket.enqueue(
          "again", failurePolicy: overrides ? failure : nil, policy: overrides ? admission : nil)
        Issue.record("An overlapping send was admitted")
      } catch let error {
        #expect(error.kind == (admission == .serialize ? .sendQueueFull : .concurrentOperation))
      }
      if failure == .abortConnection {
        await #expect(throws: WebSocketError.self) { try await first.wait() }
        #expect(fixture.backend.operations.contains(.cancel))
      } else {
        #expect(!fixture.backend.operations.contains(.cancel))
        held.release()
        try await first.wait()
        try await fixture.socket.send("later")
        #expect(fixture.sent == [.text("first"), .text("later")])
      }
    }
  }

  @Test("Async send cancellation cancels its queued operation and immediately returns capacity")
  func asyncCancellationRemovesQueuedSend() async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(maxPendingSendMessages: 2),
      steps: [.init(gate: held, result: .success(.completed)), .init(result: .success(.completed))])
    defer { fixture.socket.cancel() }
    let first = try fixture.socket.enqueue("first")
    try await held.waitForArrival()
    let queued = Task.immediate { @MainActor in try await fixture.socket.send("removed") }
    queued.cancel()
    await #expect { try await queued.value } throws: { ($0 as? WebSocketError)?.kind == .cancelled }
    let replacement = try fixture.socket.enqueue("replacement")
    held.release()
    try await first.wait()
    try await replacement.wait()
    #expect(fixture.sent == [.text("first"), .text("replacement")])
  }

  @Test(
    "A backend write failure aborts before a successor writes",
    arguments: [
      WebSocket.SendFailurePolicy.abortConnection, .preserveIfUnsent,
    ])
  func backendFailureStopsSuccessors(_ failure: WebSocket.SendFailurePolicy) async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(steps: [
      .init(gate: held, result: .failure(WebSocketError(kind: .transport)))
    ])
    let first = try fixture.socket.enqueue("first", failurePolicy: failure)
    try await held.waitForArrival()
    let next = try fixture.socket.enqueue("next")
    held.release()
    await #expect { try await first.wait() } throws: { ($0 as? WebSocketError)?.kind == .transport }
    await #expect { try await next.wait() } throws: { ($0 as? WebSocketError)?.kind == .transport }
    #expect(fixture.sent == [.text("first")])
    #expect(fixture.backend.operations.filter { $0 == .cancel }.count == 1)
  }

  @Test("Byte and count limits include active sends, UTF-8 text, binary and empty messages")
  func byteAndCountBoundaries() async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(maxMessageBytes: 4, maxPendingSendBytes: 4, maxPendingSendMessages: 3),
      steps: [
        .init(gate: held, result: .success(.completed)),
        .init(result: .success(.completed)), .init(result: .success(.completed)),
      ])
    defer { fixture.socket.cancel() }
    let first = try fixture.socket.enqueue("é")
    try await held.waitForArrival()
    let second = try fixture.socket.enqueue(Data([1, 2]))
    #expect(throws: WebSocketError.self) { try fixture.socket.enqueue("x") }
    let empty = try fixture.socket.enqueue("")
    #expect(throws: WebSocketError.self) { try fixture.socket.enqueue("") }
    #expect(!fixture.backend.operations.contains(.cancel))
    held.release()
    try await first.wait()
    try await second.wait()
    try await empty.wait()
    #expect(fixture.sent == [.text("é"), .binary(Data([1, 2])), .text("")])
  }

  @Test(
    "Cancellation racing write start either removes the message or aborts its active write",
    arguments: 0..<4, [WebSocket.SendFailurePolicy.abortConnection, .preserveIfUnsent])
  func cancellationRacesWriteStart(_ iteration: Int, _ policy: WebSocket.SendFailurePolicy)
    async throws
  {
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
    let second = try fixture.socket.enqueue("second", failurePolicy: policy)
    async let cancel: Void = {
      try? await race.arriveAndWait()
      second.cancel()
    }()
    async let finish: Void = {
      try? await race.arriveAndWait()
      firstGate.release()
    }()
    try await race.waitForArrival(count: 2)
    race.release()
    _ = await (cancel, finish)
    do { try await first.wait() } catch {
      #expect(policy == .abortConnection && error.kind == .cancelled)
    }
    await #expect { try await second.wait() } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
    if policy == .abortConnection || fixture.sent.contains(.text("second")) {
      #expect(fixture.backend.operations.contains(.cancel))
    } else {
      #expect(fixture.sent == [.text("first")])
      #expect(!fixture.backend.operations.contains(.cancel))
    }
    await #expect { try await second.wait() } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
  }

  @Test("Concurrent producers admit only the configured count while a write is held")
  func concurrentProducersRespectCapacity() async throws {
    let held = WebSocketRendezvous()
    let race = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(maxPendingSendMessages: 4),
      steps: [.init(gate: held, result: .success(.completed))]
        + Array(repeating: .init(result: .success(.completed)), count: 3))
    defer { fixture.socket.cancel() }
    let first = try fixture.socket.enqueue("first")
    try await held.waitForArrival()
    let socket = fixture.socket
    let results = await withTaskGroup(of: WebSocket.SendOperation?.self) { group in
      for number in 0..<8 {
        group.addTask {
          try? await race.arriveAndWait()
          do throws(WebSocketError) {
            return try socket.enqueue(String(number))
          } catch {
            #expect(error.kind == .sendQueueFull)
            return nil
          }
        }
      }
      try? await race.waitForArrival(count: 8)
      race.release()
      var admitted: [WebSocket.SendOperation] = []
      for await operation in group { if let operation { admitted.append(operation) } }
      return admitted
    }
    #expect(results.count == 3)
    #expect(fixture.sent == [.text("first")])
    held.release()
    try await first.wait()
    for result in results { try await result.wait() }
    #expect(fixture.sent.count == 4)
  }

  @Test("Larger limits admit beyond both defaults and options remain captured")
  func customLimitsAndCapturedOptions() async throws {
    let held = WebSocketRendezvous()
    var options = WebSocket.Options(
      maxMessageBytes: 1_048_577, maxPendingSendBytes: 1_048_577, maxPendingSendMessages: 17)
    options.maxBufferedBytes = 1_048_577
    let fixture = try await SendFixture.open(
      options: options,
      steps: [.init(gate: held, result: .success(.completed))]
        + Array(repeating: .init(result: .success(.completed)), count: 16))
    defer { fixture.socket.cancel() }
    options.maxPendingSendMessages = 1
    options.sendPolicy = .rejectOverlapping
    let first = try fixture.socket.enqueue(Data(repeating: 1, count: 1_048_577))
    try await held.waitForArrival()
    let rest = try (0..<16).map { _ in try fixture.socket.enqueue("") }
    #expect(throws: WebSocketError.self) { try fixture.socket.enqueue("") }
    held.release()
    try await first.wait()
    for operation in rest { try await operation.wait() }
    #expect(fixture.sent.count == 17)
  }

  @Test(
    "Active send deadlines are configurable and abort under both admission policies",
    arguments: [WebSocket.SendPolicy.rejectOverlapping, .serialize],
    [Duration.seconds(30), .seconds(2)])
  func deadlineAbortsActive(_ policy: WebSocket.SendPolicy, _ duration: Duration) async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(sendPolicy: policy, sendTimeout: duration),
      steps: [.init(gate: held, result: .success(.completed))])
    let operation = try fixture.socket.enqueue("active")
    try await held.waitForArrival()
    await fixture.clock.underlying.waitForPendingSleep()
    fixture.clock.underlying.advance(by: duration)
    await #expect { try await operation.wait() } throws: {
      ($0 as? WebSocketError)?.kind == .timedOut
    }
    #expect(fixture.backend.operations.filter { $0 == .cancel }.count == 1)
    try await fixture.clock.completed.waitForArrival(count: 2)
    #expect(fixture.clock.underlying.pendingSleeps == 0)
  }

  @Test("Completed operations retain results without keeping the connection alive")
  func droppingSocketSettlesOperations() async throws {
    let receive = WebSocketRendezvous()
    let write = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(steps: [
      .init(gate: receive, result: .success(.message(nil))),
      .init(gate: write, result: .success(.completed)),
    ])
    var socket: WebSocket? = try await WebSocketClient(
      clock: RecordingClock(),
      transport: MockWebSocketTransport(answers: [.init(result: .success(backend))])
    ).connect(to: #require(URL(string: "wss://example.com")))
    try await receive.waitForArrival()
    let first = try #require(socket).enqueue("first")
    try await write.waitForArrival()
    let second = try #require(socket).enqueue("second")
    socket = nil
    #expect(backend.operations.filter { $0 == .cancel }.count == 1)
    for operation in [first, second] {
      await #expect { try await operation.wait() } throws: {
        ($0 as? WebSocketError)?.kind == .cancelled
      }
    }
  }

  @Test(
    "Invalid send capacities and deadlines fail before connection work",
    arguments: [
      WebSocket.Options(maxMessageBytes: 2, maxPendingSendBytes: 1),
      WebSocket.Options(maxPendingSendBytes: 0),
      WebSocket.Options(maxPendingSendMessages: -1),
      WebSocket.Options(sendTimeout: .zero),
      WebSocket.Options(sendTimeout: .seconds(-1)),
    ])
  func invalidSendOptions(_ options: WebSocket.Options) async throws {
    let transport = MockWebSocketTransport()
    await #expect {
      try await WebSocketClient(transport: transport).connect(
        to: #require(URL(string: "wss://example.com")), options: options)
    } throws: { ($0 as? WebSocketError)?.kind == .invalidRequest }
    #expect(transport.calls.isEmpty)
  }

  @Test("Sequential enqueue and async send share FIFO including per-send serialization")
  func mixedCallsShareFIFO() async throws {
    let firstGate = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(sendPolicy: .rejectOverlapping),
      steps: [.init(gate: firstGate, result: .success(.completed))]
        + Array(repeating: .init(result: .success(.completed)), count: 3))
    defer { fixture.socket.cancel() }
    let first = try fixture.socket.enqueue("a")
    try await firstGate.waitForArrival()
    let second = try fixture.socket.enqueue(Data([2]), policy: .serialize)
    let third = Task.immediate { @MainActor in
      try await fixture.socket.send(.text("c"), policy: .serialize)
    }
    let fourth = try fixture.socket.enqueue(.text("d"), policy: .serialize)
    #expect(throws: WebSocketError.self) { try fixture.socket.enqueue("rejected") }
    #expect(fixture.sent == [.text("a")])
    firstGate.release()
    try await first.wait()
    try await second.wait()
    try await third.value
    try await fourth.wait()
    #expect(fixture.sent == [.text("a"), .binary(Data([2])), .text("c"), .text("d")])
  }

  @Test("Observers share completion while cancellation removes only its own wait")
  func multipleObserversCancelIndependently() async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(sendFailurePolicy: .abortConnection),
      steps: [.init(gate: held, result: .success(.completed))])
    defer { fixture.socket.cancel() }
    let operation = try fixture.socket.enqueue("one")
    try await held.waitForArrival()
    let waiters = (0..<8).map { _ in Task.immediate { @MainActor in try await operation.wait() } }
    waiters[0].cancel()
    await #expect { try await waiters[0].value } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
    #expect(!fixture.backend.operations.contains(.cancel))
    held.release()
    for waiter in waiters.dropFirst() { try await waiter.value }
    operation.cancel()
    try await operation.wait()
    try await operation.wait()
    #expect(fixture.sent == [.text("one")])
    #expect(!fixture.backend.operations.contains(.cancel))
  }

  @Test(
    "Pre-cancelled sends follow their failure policy without starting a write",
    arguments: [WebSocket.SendFailurePolicy.abortConnection, .preserveIfUnsent])
  func preCancelledAdmission(_ policy: WebSocket.SendFailurePolicy) async throws {
    let fixture = try await SendFixture.open(steps: [])
    defer { fixture.socket.cancel() }
    let entry = WebSocketRendezvous()
    let task = Task {
      try? await entry.arriveAndWait()
      return try fixture.socket.enqueue("cancelled", failurePolicy: policy)
    }
    try await entry.waitForArrival()
    task.cancel()
    await #expect { try await task.value } throws: { ($0 as? WebSocketError)?.kind == .cancelled }
    #expect(fixture.sent.isEmpty)
    #expect(fixture.backend.operations.contains(.cancel) == (policy == .abortConnection))
  }

  @Test("Producer rendezvous establish FIFO independently of task scheduling")
  func producerRendezvousEstablishFIFO() async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(maxPendingSendMessages: 5),
      steps: [.init(gate: held, result: .success(.completed))]
        + Array(repeating: .init(result: .success(.completed)), count: 4))
    defer { fixture.socket.cancel() }
    let first = try fixture.socket.enqueue("first")
    try await held.waitForArrival()
    let admitted = (0..<4).map { _ in WebSocketRendezvous() }
    let entry = (0..<4).map { _ in WebSocketRendezvous() }
    let socket = fixture.socket
    try await withThrowingTaskGroup(of: WebSocket.SendOperation.self) { group in
      for number in 0..<4 {
        group.addTask {
          try await entry[number].arriveAndWait()
          let operation = try socket.enqueue(String(number))
          admitted[number].arrive()
          return operation
        }
      }
      for gate in entry { try await gate.waitForArrival() }
      for number in [2, 0, 3, 1] {
        entry[number].release()
        try await admitted[number].waitForArrival()
      }
      #expect(fixture.sent == [.text("first")])
      held.release()
      try await first.wait()
      for try await operation in group { try await operation.wait() }
    }
    #expect(fixture.sent == ["first", "2", "0", "3", "1"].map { .text($0) })
  }

  @Test(
    "Queued cancellation releases capacity, preserves survivor order, or aborts by policy",
    arguments: [WebSocket.SendFailurePolicy.abortConnection, .preserveIfUnsent])
  func queuedCancellationFollowsPolicy(_ policy: WebSocket.SendFailurePolicy) async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(maxPendingSendMessages: 3),
      steps: [.init(gate: held, result: .success(.completed))]
        + Array(repeating: .init(result: .success(.completed)), count: 2))
    defer { fixture.socket.cancel() }
    let first = try fixture.socket.enqueue("a")
    try await held.waitForArrival()
    let removed = try fixture.socket.enqueue("b", failurePolicy: policy)
    let survivor = try fixture.socket.enqueue("c")
    removed.cancel()
    if policy == .abortConnection {
      // Check the transition before observing the initiating error.
      #expect(fixture.backend.operations.contains(.cancel))
      await #expect(throws: WebSocketError.self) { try await first.wait() }
      await #expect(throws: WebSocketError.self) { try await survivor.wait() }
    } else {
      let replacement = try fixture.socket.enqueue("d")
      held.release()
      try await first.wait()
      try await survivor.wait()
      try await replacement.wait()
      #expect(fixture.sent == [.text("a"), .text("c"), .text("d")])
    }
    await #expect { try await removed.wait() } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
    #expect(!fixture.sent.contains(.text("b")))
  }

  @Test(
    "Queue residence consumes the original deadline even when timer delivery is delayed",
    arguments: [WebSocket.SendFailurePolicy.abortConnection, .preserveIfUnsent])
  func queuedExpiryFollowsPolicy(_ policy: WebSocket.SendFailurePolicy) async throws {
    let delivery = WebSocketRendezvous()
    let held = WebSocketRendezvous()
    let clock = SendClock(delivery: delivery)
    let fixture = try await SendFixture.open(
      clock: clock,
      steps: [
        .init(gate: held, result: .success(.completed)), .init(result: .success(.completed)),
      ])
    defer { fixture.socket.cancel() }
    let first = try fixture.socket.enqueue("first")
    try await held.waitForArrival()
    let expired = try fixture.socket.enqueue("expired", failurePolicy: policy)
    await clock.underlying.waitForPendingSleep()
    clock.underlying.advance(by: .seconds(30))
    try await delivery.waitForArrival()
    // The expired timer is parked before delivering its callback. Write completion wins first.
    held.release()
    try await first.wait()
    await #expect { try await expired.wait() } throws: {
      ($0 as? WebSocketError)?.kind == .timedOut
    }
    #expect(fixture.sent == [.text("first")])
    if policy == .preserveIfUnsent {
      try await fixture.socket.send("later")
      #expect(fixture.sent == [.text("first"), .text("later")])
      #expect(!fixture.backend.operations.contains(.cancel))
    } else {
      #expect(fixture.backend.operations.contains(.cancel))
    }
    delivery.release()
  }

  @Test("A send retains its deadline when it starts writing after queue residence")
  func queueTimeIsNotRestarted() async throws {
    let firstGate = WebSocketRendezvous()
    let secondGate = WebSocketRendezvous()
    let fixture = try await SendFixture.open(steps: [
      .init(gate: firstGate, result: .success(.completed)),
      .init(gate: secondGate, result: .success(.completed)),
    ])
    let first = try fixture.socket.enqueue("first")
    try await firstGate.waitForArrival()
    fixture.clock.underlying.advance(by: .seconds(5))
    let second = try fixture.socket.enqueue("second")
    fixture.clock.underlying.advance(by: .seconds(20))
    firstGate.release()
    try await first.wait()
    try await secondGate.waitForArrival()
    try await fixture.clock.completed.waitForArrival(count: 2)
    await fixture.clock.underlying.waitForPendingSleep()
    fixture.clock.underlying.advance(by: .seconds(10))
    await #expect { try await second.wait() } throws: { ($0 as? WebSocketError)?.kind == .timedOut }
    #expect(fixture.clock.underlying.now == RecordingClock().now.advanced(by: .seconds(35)))
  }

  @Test(
    "Sends overlap an independent receive and ping under either admission policy",
    arguments: [WebSocket.SendPolicy.rejectOverlapping, .serialize])
  func sendReceivePingOverlap(_ policy: WebSocket.SendPolicy) async throws {
    let held = WebSocketRendezvous()
    let pong = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(sendPolicy: policy),
      steps: [
        .init(gate: held, result: .success(.completed)),
        .init(gate: pong, result: .success(.completed)),
      ])
    defer { fixture.socket.cancel() }
    let send = try fixture.socket.enqueue("send")
    try await held.waitForArrival()
    let ping = Task { try await fixture.socket.ping() }
    try await pong.waitForArrival()
    #expect(fixture.backend.operations == [.receive, .send(.text("send")), .ping])
    pong.release()
    try await ping.value
    held.release()
    try await send.wait()
  }

  @Test(
    "Oversized UTF-8 input follows failure policy before write admission",
    arguments: [WebSocket.SendFailurePolicy.abortConnection, .preserveIfUnsent])
  func validationFollowsFailurePolicy(_ policy: WebSocket.SendFailurePolicy) async throws {
    let fixture = try await SendFixture.open(
      options: .init(maxMessageBytes: 2), steps: [.init(result: .success(.completed))])
    defer { fixture.socket.cancel() }
    #expect {
      try fixture.socket.enqueue("€", failurePolicy: policy)
    } throws: { ($0 as? WebSocketError)?.kind == .messageTooLarge }
    #expect(fixture.sent.isEmpty)
    #expect(fixture.backend.operations.contains(.cancel) == (policy == .abortConnection))
    if policy == .preserveIfUnsent { try await fixture.socket.send("é") }
  }

}
