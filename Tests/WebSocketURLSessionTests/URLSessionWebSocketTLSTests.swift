#if canImport(Darwin)
import Foundation
import HTTPTesting
import Testing
import WebSocketCore
@testable import WebSocketURLSession

@Suite("URLSession WebSocket TLS", .serialized, .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct URLSessionWebSocketTLSTests {
  @Test("Cancelling during TLS stops a pending connection")
  func cancelledHandshake() async throws {
    let server = try WebSocketServer { _, _ in }
    defer { server.stop() }
    let base = try await server.url()
    var components = try #require(URLComponents(url: base, resolvingAgainstBaseURL: false))
    components.scheme = "wss"
    let url = try #require(components.url)
    let opening = Task {
      try await WebSocketClient(transport: URLSessionWebSocketTransport()).connect(to: url)
    }
    try await server.accepted.wait()
    opening.cancel()
    await #expect { try await opening.value } throws: {
      ($0 as? WebSocketError)?.kind == .cancelled
    }
  }

  @Test("A trusted local CA still rejects the wrong hostname")
  func hostnameMismatch() async throws {
    let server = try AppleTLSFixture.server { peer, request in
      try await peer.upgrade(request)
    }
    defer { server.stop() }
    let client = WebSocketClient(
      transport: URLSessionWebSocketTransport(
        testTrustAnchor: try AppleTLSFixture.certificate.get()))
    await #expect { try await client.connect(to: server.url()) } throws: {
      ($0 as? WebSocketError)?.kind == .handshakeRejected
    }
    #expect(server.requests.withLock { $0.isEmpty })
  }

  @Test("A trusted local CA completes a WSS upgrade and message exchange")
  func trustedCA() async throws {
    let server = try AppleTLSFixture.server { peer, request in
      try await peer.upgrade(request, frames: [0x81, 2, 111, 107])
      _ = try await peer.frame()
    }
    defer { server.stop() }
    let client = WebSocketClient(
      transport: URLSessionWebSocketTransport(
        testTrustAnchor: try AppleTLSFixture.certificate.get()))
    let socket = try await client.connect(to: server.url(host: "localhost"))
    defer { socket.cancel() }
    var messages = socket.messages.makeAsyncIterator()
    #expect(try await messages.next() == .text("ok"))
    try await socket.send("done")
  }

  @Test("An untrusted local CA is rejected by the public transport")
  func untrustedCA() async throws {
    let server = try AppleTLSFixture.server { peer, request in
      try await peer.upgrade(request)
    }
    defer { server.stop() }
    let client = WebSocketClient(transport: URLSessionWebSocketTransport())
    await #expect { try await client.connect(to: server.url(host: "localhost")) } throws: {
      ($0 as? WebSocketError)?.kind == .handshakeRejected
    }
    #expect(server.requests.withLock { $0.isEmpty })
  }
}
#endif
