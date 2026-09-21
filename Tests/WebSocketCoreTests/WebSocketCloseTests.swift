import HTTPTesting
import Testing
import WebSocketCore

@Suite("WebSocket close", .timeLimit(.minutes(suiteTimeLimitMinutes)))
@MainActor
struct WebSocketCloseTests {
  @Test(
    "Cancelling a close caller either detaches it or aborts all joined callers",
    arguments: [WebSocket.CloseCancellationPolicy.abortConnection, .stopWaiting])
  func cancellationPolicy(_ policy: WebSocket.CloseCancellationPolicy) async throws {
    let closeGate = WebSocketRendezvous()
    let peer = WebSocketClose(code: .init(rawValue: 4001), reason: "peer")
    let fixture = try await SendFixture.open(steps: [
      .init(gate: closeGate, result: .success(.close(peer)))
    ])
    defer { fixture.socket.cancel() }
    let first = Task.immediate { @MainActor in
      try await fixture.socket.close(cancellation: policy, code: .goingAway, reason: "first")
    }
    try await closeGate.waitForArrival()
    let second = Task.immediate { @MainActor in try await fixture.socket.close() }
    first.cancel()
    await #expect { try await first.value } throws: { ($0 as? WebSocketError)?.kind == .cancelled }
    if policy == .stopWaiting {
      #expect(!fixture.backend.operations.contains(.cancel))
      closeGate.release()
      #expect(try await second.value == peer)
      #expect(try await fixture.socket.close() == peer)
    } else {
      await #expect { try await second.value } throws: {
        ($0 as? WebSocketError)?.kind == .cancelled
      }
    }
    #expect(
      fixture.backend.operations.filter {
        if case .close = $0 { return true }
        return false
      } == [.close(code: .goingAway, reason: "first")])
    #expect(fixture.backend.operations.filter { $0 == .cancel }.count == 1)
  }

  @Test("Close atomically rejects queued sends without applying their abort policy")
  func closePreservesOnlyActiveWrite() async throws {
    let write = WebSocketRendezvous()
    let close = WebSocketRendezvous()
    let peer = WebSocketClose()
    let fixture = try await SendFixture.open(steps: [
      .init(gate: write, result: .success(.completed)),
      .init(gate: close, result: .success(.close(peer))),
    ])
    let active = try fixture.socket.enqueue("active")
    try await write.waitForArrival()
    let queued = try fixture.socket.enqueue("queued", failurePolicy: .abortConnection)
    let closing = Task.immediate { @MainActor in try await fixture.socket.close() }
    await #expect { try await queued.wait() } throws: { ($0 as? WebSocketError)?.kind == .closed }
    #expect { try fixture.socket.enqueue("late", failurePolicy: .abortConnection) } throws: {
      ($0 as? WebSocketError)?.kind == .closed
    }
    #expect(fixture.backend.operations == [.receive, .send(.text("active"))])
    write.release()
    try await active.wait()
    try await close.waitForArrival()
    #expect(
      fixture.backend.operations == [
        .receive, .send(.text("active")), .close(code: .normalClosure, reason: nil),
      ])
    close.release()
    #expect(try await closing.value == peer)
    #expect(fixture.socket.closeInfo == peer)
  }

  @Test(
    "Close racing synchronous admission never writes a rejected message after its close frame",
    arguments: 0..<4, [WebSocket.SendPolicy.rejectOverlapping, .serialize])
  func closeRacesAdmission(_ iteration: Int, _ policy: WebSocket.SendPolicy) async throws {
    let write = WebSocketRendezvous()
    let close = WebSocketRendezvous()
    let race = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(sendPolicy: policy),
      steps: [
        .init(gate: write, result: .success(.completed)),
        .init(gate: close, result: .success(.close(.init()))),
      ])
    let first = try fixture.socket.enqueue("first")
    try await write.waitForArrival()
    let socket = fixture.socket
    let closing = Task {
      try await race.arriveAndWait()
      return try await socket.close()
    }
    let enqueue = Task {
      try await race.arriveAndWait()
      return try socket.enqueue("racer")
    }
    try await race.waitForArrival(count: 2)
    race.release()
    do {
      let admitted = try await enqueue.value
      await #expect { try await admitted.wait() } throws: {
        ($0 as? WebSocketError)?.kind == .closed
      }
    } catch {
      #expect(
        [WebSocketError.Kind.closed, .concurrentOperation].contains(
          (error as? WebSocketError)?.kind ?? .transport))
    }
    // Awaiting the close deadline registration establishes that close admission has finished.
    await fixture.clock.underlying.waitForPendingSleep(count: 2)
    write.release()
    try await first.wait()
    try await close.waitForArrival()
    close.release()
    _ = try await closing.value
    #expect(fixture.sent == [.text("first")])
  }

  @Test("The close deadline includes its active-write wait and releases every joined caller")
  func deadlineIncludesActiveWrite() async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(closeTimeout: .seconds(3)),
      steps: [.init(gate: held, result: .success(.completed))])
    let active = try fixture.socket.enqueue("active")
    try await held.waitForArrival()
    let first = Task.immediate { @MainActor in try await fixture.socket.close() }
    fixture.clock.underlying.advance(by: .seconds(2))
    let second = Task.immediate { @MainActor in try await fixture.socket.close() }
    await fixture.clock.underlying.waitForPendingSleep(count: 2)
    fixture.clock.underlying.advance(by: .seconds(1))
    for task in [first, second] {
      await #expect { try await task.value } throws: { ($0 as? WebSocketError)?.kind == .timedOut }
    }
    await #expect { try await active.wait() } throws: { ($0 as? WebSocketError)?.kind == .timedOut }
    #expect(fixture.backend.operations == [.receive, .send(.text("active")), .cancel])
    try await fixture.clock.completed.waitForArrival(count: 3)
    #expect(fixture.clock.underlying.pendingSleeps == 0)
  }

  @Test("A detached close waiter leaves the original close deadline running")
  func detachedWaiterKeepsDeadline() async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(steps: [
      .init(gate: held, result: .success(.close(.init())))
    ])
    let caller = Task.immediate { @MainActor in try await fixture.socket.close() }
    try await held.waitForArrival()
    caller.cancel()
    await #expect { try await caller.value } throws: { ($0 as? WebSocketError)?.kind == .cancelled }
    #expect(!fixture.backend.operations.contains(.cancel))
    await fixture.clock.underlying.waitForPendingSleep()
    fixture.clock.underlying.advance(by: .seconds(5))
    try await fixture.backend.waitForCancellation()
    await #expect { try await fixture.socket.close() } throws: {
      ($0 as? WebSocketError)?.kind == .timedOut
    }
  }

  @Test(
    "Invalid close arguments have no effect on a live connection",
    arguments: [UInt16(999), 1004, 1005, 1006, 1015, 2000, 5000])
  func invalidCodesHaveNoEffect(_ code: UInt16) async throws {
    let fixture = try await SendFixture.open(steps: [.init(result: .success(.completed))])
    defer { fixture.socket.cancel() }
    await #expect { try await fixture.socket.close(code: .init(rawValue: code)) } throws: {
      ($0 as? WebSocketError)?.kind == .invalidRequest
    }
    #expect(fixture.backend.operations == [.receive])
    try await fixture.socket.send("healthy")
  }

  @Test(
    "Pre-cancelled close starts nothing under either policy",
    arguments: [WebSocket.CloseCancellationPolicy.abortConnection, .stopWaiting])
  func preCancelledCloseHasNoEffect(_ policy: WebSocket.CloseCancellationPolicy) async throws {
    let fixture = try await SendFixture.open(steps: [.init(result: .success(.completed))])
    defer { fixture.socket.cancel() }
    let entry = WebSocketRendezvous()
    let task = Task {
      try? await entry.arriveAndWait()
      return try await fixture.socket.close(cancellation: policy)
    }
    try await entry.waitForArrival()
    task.cancel()
    await #expect { try await task.value } throws: { ($0 as? WebSocketError)?.kind == .cancelled }
    #expect(fixture.backend.operations == [.receive])
    try await fixture.socket.send("healthy")
  }

  @Test("Close reasons use the 123-byte UTF-8 boundary and preserve application codes")
  func reasonBoundaryAndRawCodes() async throws {
    let fixture = try await SendFixture.open(steps: [.init(result: .success(.close(.init())))])
    await #expect {
      try await fixture.socket.close(reason: String(repeating: "é", count: 62))
    } throws: { ($0 as? WebSocketError)?.kind == .invalidRequest }
    #expect(fixture.backend.operations == [.receive])
    let reason = String(repeating: "é", count: 61) + "x"
    _ = try await fixture.socket.close(code: .init(rawValue: 4001), reason: reason)
    #expect(
      fixture.backend.operations.contains(.close(code: .init(rawValue: 4001), reason: reason)))
  }

  @Test("An active send deadline may abort before the close deadline")
  func sendDeadlineCanWin() async throws {
    let held = WebSocketRendezvous()
    let fixture = try await SendFixture.open(
      options: .init(sendTimeout: .seconds(1)),
      steps: [.init(gate: held, result: .success(.completed))])
    let send = try fixture.socket.enqueue("active")
    try await held.waitForArrival()
    let close = Task.immediate { @MainActor in try await fixture.socket.close() }
    await fixture.clock.underlying.waitForPendingSleep(count: 2)
    fixture.clock.underlying.advance(by: .seconds(1))
    await #expect { try await send.wait() } throws: { ($0 as? WebSocketError)?.kind == .timedOut }
    await #expect { try await close.value } throws: { ($0 as? WebSocketError)?.kind == .timedOut }
    #expect(fixture.backend.operations == [.receive, .send(.text("active")), .cancel])
  }

}
