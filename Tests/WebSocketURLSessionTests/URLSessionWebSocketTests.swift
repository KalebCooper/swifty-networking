#if canImport(Darwin)
import Foundation
import HTTPTesting
import Testing
import WebSocketCore
@testable import WebSocketURLSession

@Suite("URLSession WebSockets", .serialized, .timeLimit(.minutes(suiteTimeLimitMinutes)))
@MainActor
struct URLSessionWebSocketTests {
  @Test("Abrupt EOF fails rather than inventing close metadata")
  func abruptEOF() async throws {
    let server = try WebSocketServer { peer, request in try await peer.upgrade(request) }
    defer { server.stop() }
    let socket = try await WebSocketClient(transport: URLSessionWebSocketTransport())
      .connect(to: server.url())
    defer { socket.cancel() }
    var reader = socket.messages.makeAsyncIterator()
    await #expect { try await reader.next() } throws: {
      ($0 as? WebSocketError)?.kind == .transport
    }
    #expect(socket.closeInfo == nil)
  }

  @Test("Cancelling connect stops a pending upgrade and leaves later connections usable")
  func cancelledConnect() async throws {
    let arrived = WebSocketRendezvous()
    let release = WebSocketRendezvous()
    let server = try WebSocketServer { peer, request in
      if request.contains("/held ") {
        try await arrived.arriveAndWait()
      }
      try await peer.upgrade(request)
      try await release.arriveAndWait()
    }
    defer { arrived.release(); release.release(); server.stop() }
    let transport = URLSessionWebSocketTransport()
    let client = WebSocketClient(transport: transport)
    let url = try await server.url("/held")
    let opening = Task { try await client.connect(to: url) }
    try await arrived.waitForArrival()
    opening.cancel()
    await #expect { try await opening.value } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
    let socket = try await client.connect(to: server.url("/next"))
    socket.cancel()
  }

  @Test("A Set-Cookie response does not add cookies to later connections")
  func cookieIsolation() async throws {
    let server = try WebSocketServer { peer, request in
      try await peer.upgrade(request, extra: "Set-Cookie: session=hidden; Path=/\r\n")
      _ = try await peer.frame()
    }
    defer { server.stop() }
    let client = WebSocketClient(transport: URLSessionWebSocketTransport())
    let first = try await client.connect(to: server.url())
    try await first.close()
    let second = try await client.connect(to: server.url())
    try await second.close()
    let requests = server.requests.withLock { $0 }
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { !$0.lowercased().contains("cookie:") })
  }

  @Test(
    "Handshake failures preserve real status and never follow redirects", arguments: [401, 307, 0])
  func handshakeFailure(status: Int) async throws {
    let server = try WebSocketServer { peer, request in
      if status == 0 { return }
      let reply =
        "HTTP/1.1 \(status) Rejected\r\nContent-Length: 0\r\nConnection: close\r\nWWW-Authenticate: Basic realm=\"fixture\"\r\nLocation: /target\r\n\r\n"
      try await peer.send(Array(reply.utf8))
    }
    defer { server.stop() }
    do {
      let socket = try await WebSocketClient(transport: URLSessionWebSocketTransport())
        .connect(to: server.url())
      socket.cancel()
      Issue.record("Expected a rejected handshake")
    } catch let error as WebSocketError {
      #expect(error.kind == .handshakeRejected)
      #expect(error.response?.status.code == (status == 0 ? nil : status))
      if status == 401 {
        #expect(error.response?.headerFields[.wwwAuthenticate] == "Basic realm=\"fixture\"")
      }
    }
    let requests = server.requests.withLock { $0 }
    #expect(!requests.isEmpty)
    #expect(requests.allSatisfy { $0.hasPrefix("GET / HTTP/1.1") })
    if status != 0 { #expect(requests.count == 1) }
  }

  @Test(
    "Local close returns backend metadata without promising a peer acknowledgement",
    arguments: [false, true])
  func localClose(reply: Bool) async throws {
    let server = try WebSocketServer { peer, request in
      try await peer.upgrade(request)
      // Whether the backend delivers its close frame before tearing down varies by OS release,
      // and a local close promises no delivery, so the peer replies only to a frame it received.
      guard let frame = try? await peer.frame(), frame.opcode == 8 else { return }
      if reply { try await peer.send([0x88, 6, 15, 162, 112, 101, 101, 114]) }
    }
    defer { server.stop() }
    let socket = try await WebSocketClient(transport: URLSessionWebSocketTransport())
      .connect(to: server.url())
    let closed = try await socket.close(code: .init(rawValue: 4001), reason: "local")
    #expect(closed == WebSocketClose(code: .init(rawValue: 4001), reason: "local"))
    #expect(socket.closeInfo == closed)
    #expect(try await socket.close() == closed)
  }

  @Test("Peer close preserves raw codes and an absent wire code", arguments: [false, true])
  func peerClose(empty: Bool) async throws {
    let server = try WebSocketServer { peer, request in
      try await peer.upgrade(request, frames: empty ? [0x88, 0] : [0x88, 3, 15, 161, 120])
      _ = try await peer.frame()
    }
    defer { server.stop() }
    let socket = try await WebSocketClient(transport: URLSessionWebSocketTransport())
      .connect(to: server.url())
    var reader = socket.messages.makeAsyncIterator()
    #expect(try await reader.next() == nil)
    #expect(
      socket.closeInfo
        == WebSocketClose(
          code: empty ? nil : .init(rawValue: 4001), reason: empty ? nil : "x"))
  }

  @Test("Text and binary sends share the connection with ping and fragmented receiving")
  func sendReceiveAndControl() async throws {
    let pong = WebSocketCompletion<WebSocketServer.Frame>()
    let received = WebSocketCompletion<[[UInt8]]>()
    let server = try WebSocketServer { peer, request in
      try await peer.upgrade(
        request, extra: "Sec-WebSocket-Protocol: updates.v1\r\n",
        frames: [0x01, 1, 0xc3, 0x89, 1, 120, 0x80, 1, 0xa9])
      var messages: [[UInt8]] = []
      while true {
        let frame = try await peer.frame()
        switch frame.opcode {
        case 1, 2:
          messages.append(frame.payload)
          if messages.count == 2 { received.finish(.success(messages)) }
        case 8:
          try await peer.send([0x88, 2, 3, 232])
          return
        case 9: try await peer.send([0x8a, UInt8(frame.payload.count)] + frame.payload)
        case 10: pong.finish(.success(frame))
        default: break
        }
      }
    }
    defer { server.stop() }
    let url = try await server.url("/a%2Fb?value=%2B")
    let request = WebSocketRequest(
      headers: [.cookie: "explicit=value", .origin: "https://example.test"],
      subprotocols: ["updates.v1"], url: url)
    let socket = try await WebSocketClient(transport: URLSessionWebSocketTransport()).connect(
      request)
    defer { socket.cancel() }
    #expect(socket.negotiatedSubprotocol == "updates.v1")
    var reader = socket.messages.makeAsyncIterator()
    #expect(try await reader.next() == .text("é"))
    #expect(try await pong.wait().payload == [120])
    let first = try socket.enqueue("first")
    let second = try socket.enqueue(Data([0, 1, 255]))
    try await first.wait()
    try await second.wait()
    #expect(try await received.wait() == [[102, 105, 114, 115, 116], [0, 1, 255]])
    try await socket.ping()
    try await socket.close()
    let sent = try #require(server.requests.withLock { $0.first })
    #expect(sent.contains("GET /a%2Fb?value=%2B HTTP/1.1"))
    #expect(sent.lowercased().contains("cookie: explicit=value"))
    #expect(sent.lowercased().contains("origin: https://example.test"))
  }

  @Test("Unsolicited subprotocol selection never returns a connection")
  func unsolicitedProtocol() async throws {
    let server = try WebSocketServer { peer, request in
      try await peer.upgrade(request, extra: "Sec-WebSocket-Protocol: unexpected\r\n")
      _ = try await peer.frame()
    }
    defer { server.stop() }
    await #expect {
      try await WebSocketClient(transport: URLSessionWebSocketTransport()).connect(to: server.url())
    } throws: { ($0 as? WebSocketError)?.kind == .handshakeRejected }
  }
}
#endif
