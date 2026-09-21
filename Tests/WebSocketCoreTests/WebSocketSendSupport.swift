#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTesting
import Testing
import WebSocketCore

/// Gates timer delivery separately from advancing its clock, and records timer cleanup.
struct SendClock: Clock {
  typealias Duration = Swift.Duration
  typealias Instant = RecordingClock.Instant

  let completed = WebSocketRendezvous()
  let delivery: WebSocketRendezvous?
  let underlying = RecordingClock()

  init(delivery: WebSocketRendezvous? = nil) { self.delivery = delivery }

  var minimumResolution: Duration { .zero }
  var now: Instant { underlying.now }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    defer { completed.arrive() }
    try await underlying.sleep(until: deadline, tolerance: tolerance)
    if let delivery { try await delivery.arriveAndWait() }
  }
}

@MainActor
struct SendFixture {
  let backend: ScriptedWebSocketConnection
  let clock: SendClock
  let socket: WebSocket

  static func open(
    clock: SendClock = SendClock(),
    options: WebSocket.Options = .init(),
    steps: [ScriptedWebSocketConnection.Step]
  ) async throws -> SendFixture {
    let receive = WebSocketRendezvous()
    let backend = ScriptedWebSocketConnection(
      steps: [
        .init(gate: receive, result: .success(.message(nil)))
      ] + steps)
    let socket = try await WebSocketClient(
      clock: clock, transport: MockWebSocketTransport(answers: [.init(result: .success(backend))])
    ).connect(to: #require(URL(string: "wss://example.com/socket")), options: options)
    try await receive.waitForArrival()
    try await clock.completed.waitForArrival()
    return SendFixture(backend: backend, clock: clock, socket: socket)
  }

  var sent: [WebSocket.Message] {
    backend.operations.compactMap {
      if case .send(let message) = $0 { return message }
      return nil
    }
  }
}
