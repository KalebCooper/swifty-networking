#if canImport(Darwin)
import Foundation
import HTTPTesting
import Testing
import WebSocketCore
import WebSocketTestSupport
@testable import WebSocketURLSession

@Suite("URLSession WebSocket lifetime", .serialized, .timeLimit(.minutes(suiteTimeLimitMinutes)))
@MainActor
struct URLSessionWebSocketLifecycleTests {
  @Test("A cancelled reader releases its claim and preserves later messages")
  func cancelledReader() async throws {
    let permit = WebSocketRendezvous()
    let server = try WebSocketServer { peer, request in
      try await peer.upgrade(request)
      try await permit.arriveAndWait()
      try await peer.send([0x81, 1, 97, 0x81, 1, 98])
      _ = try await peer.frame()
    }
    defer { permit.release(); server.stop() }
    let socket = try await WebSocketClient(transport: URLSessionWebSocketTransport())
      .connect(to: server.url())
    defer { socket.cancel() }
    let waiting = Task.immediate { @MainActor in
      var iterator = socket.messages.makeAsyncIterator()
      return try await iterator.next()
    }
    waiting.cancel()
    await #expect { try await waiting.value } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
    permit.release()
    var reader = socket.messages.makeAsyncIterator()
    #expect(try await reader.next() == .text("a"))
    #expect(try await reader.next() == .text("b"))
    try await socket.close()
  }

  @Test("A connect deadline aborts its physical task")
  func connectDeadline() async throws {
    let clock = WebSocketCompletionClock()
    let requestReceived = WebSocketRendezvous()
    let server = try WebSocketServer { _, _ in try await requestReceived.arriveAndWait() }
    defer { requestReceived.release(); server.stop() }
    var transport: URLSessionWebSocketTransport? = URLSessionWebSocketTransport()
    let delegate = try #require(transport?.session.delegate)
    let url = try await server.url()
    let opening = Task { [transport] in
      try await WebSocketClient(clock: clock, transport: #require(transport))
        .connect(to: url, options: .init(connectTimeout: .seconds(3)))
    }
    try await requestReceived.waitForArrival()
    await clock.underlying.waitForPendingSleep()
    clock.underlying.advance(by: .seconds(3))
    await #expect { try await opening.value } throws: { ($0 as? WebSocketError)?.kind == .timedOut }
    transport = nil
    try await delegate.invalidation.wait()
    #expect(delegate.activeConnectionCount == 0)
  }

  @Test("Dropping all socket owners releases the task registry and owned session")
  func droppedOwners() async throws {
    let server = try WebSocketServer { peer, request in
      try await peer.upgrade(request)
      _ = try await peer.frame()
    }
    defer { server.stop() }
    var transport: URLSessionWebSocketTransport? = URLSessionWebSocketTransport()
    let delegate = try #require(transport?.session.delegate)
    var socket: WebSocket? = try await WebSocketClient(transport: #require(transport))
      .connect(to: server.url())
    weak var weakSocket = socket
    var messages = socket?.messages
    socket = nil
    transport = nil
    #expect(weakSocket == nil)
    #expect(messages != nil)
    #expect(delegate.activeConnectionCount == 1)
    messages = nil
    try await delegate.invalidation.wait()
    #expect(delegate.activeConnectionCount == 0)
  }

  @Test("A late pong releases a cancelled caller's probe and permits another ping")
  func latePong() async throws {
    let clock = WebSocketCompletionClock()
    let pong = WebSocketRendezvous()
    let server = try WebSocketServer { peer, request in
      try await peer.upgrade(request)
      let first = try await peer.frame()
      #expect(first.opcode == 9)
      try await pong.arriveAndWait()
      try await peer.send([0x8a, UInt8(first.payload.count)] + first.payload)
      let next = try await peer.frame()
      #expect(next.opcode == 9)
      try await peer.send([0x8a, UInt8(next.payload.count)] + next.payload)
      _ = try await peer.frame()
    }
    defer { pong.release(); server.stop() }
    let socket = try await WebSocketClient(clock: clock, transport: URLSessionWebSocketTransport())
      .connect(to: server.url())
    defer { socket.cancel() }
    try await clock.completed.waitForArrival()
    let first = Task { try await socket.ping() }
    try await pong.waitForArrival()
    await clock.underlying.waitForPendingSleep()
    first.cancel()
    await #expect { try await first.value } throws: { ($0 as? WebSocketError)?.kind == .cancelled }
    await #expect { try await socket.ping() } throws: {
      ($0 as? WebSocketError)?.kind == .concurrentOperation
    }
    pong.release()
    try await clock.completed.waitForArrival(count: 2)
    try await socket.ping()
  }

  @Test("A missing pong retains its deadline after caller cancellation")
  func missingPong() async throws {
    let clock = WebSocketCompletionClock()
    let ping = WebSocketRendezvous()
    let server = try WebSocketServer { peer, request in
      try await peer.upgrade(request)
      _ = try await peer.frame()
      try await ping.arriveAndWait()
    }
    defer { ping.release(); server.stop() }
    let socket = try await WebSocketClient(clock: clock, transport: URLSessionWebSocketTransport())
      .connect(to: server.url())
    defer { socket.cancel() }
    try await clock.completed.waitForArrival()
    let operation = Task { try await socket.ping() }
    try await ping.waitForArrival()
    await clock.underlying.waitForPendingSleep()
    operation.cancel()
    await #expect { try await operation.value } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
    var reader = socket.messages.makeAsyncIterator()
    let reading = Task.immediate { @MainActor in try await reader.next() }
    clock.underlying.advance(by: .seconds(10))
    await #expect { try await reading.value } throws: { ($0 as? WebSocketError)?.kind == .timedOut }
  }

  @Test(
    "Receive limits fail oversized messages and stalled inboxes without silent loss",
    arguments: [false, true])
  func receiveLimits(oversized: Bool) async throws {
    let close = WebSocketCompletion<WebSocketServer.Frame>()
    let server = try WebSocketServer { peer, request in
      try await peer.upgrade(
        request, frames: oversized ? [0x81, 3, 97, 98, 99] : [0x81, 1, 97, 0x81, 1, 98])
      let frame = try await peer.frame()
      close.finish(.success(frame))
      if frame.opcode == 8 {
        try await peer.send([0x88, UInt8(frame.payload.count)] + frame.payload)
      }
    }
    defer { server.stop() }
    let socket = try await WebSocketClient(transport: URLSessionWebSocketTransport())
      .connect(
        to: server.url(),
        options: .init(maxBufferedBytes: 2, maxBufferedMessages: 1, maxMessageBytes: 2))
    defer { socket.cancel() }
    _ = try await close.wait()
    var reader = socket.messages.makeAsyncIterator()
    await #expect { try await reader.next() } throws: {
      ($0 as? WebSocketError)?.kind == (oversized ? .messageTooLarge : .bufferOverflow)
    }
  }

  @Test("Scope exit cancels its connection without stopping another on the same session")
  func scopeAndIndependentConnections() async throws {
    let server = try WebSocketServer { peer, request in
      try await peer.upgrade(request)
      while true {
        let frame = try await peer.frame()
        if frame.opcode == 8 { return }
        if frame.opcode == 9 {
          try await peer.send([0x8a, UInt8(frame.payload.count)] + frame.payload)
        }
      }
    }
    defer { server.stop() }
    let client = WebSocketClient(transport: URLSessionWebSocketTransport())
    let url = try await server.url()
    let first = try await client.connect(to: url)
    defer { first.cancel() }
    let escaped = try await client.withConnection(to: url) { $0 }
    await #expect { try await escaped.send("late") } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
    try await first.ping()
  }
}
#endif
