#if canImport(Darwin)
import Foundation
import HTTPCore
import HTTPTesting
import Testing
import WebSocketCore
import WebSocketURLSession

@Suite(
  "URLSession WebSocket authentication", .serialized, .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct URLSessionWebSocketAuthenticationTests {
  /// Exercises HTTP response policy with fake credentials, without configuring a trusted test CA.
  /// The client validates a secure logical URL before this test-only transport routes to loopback.
  private struct LoopbackTransport: WebSocketTransport {
    let base = URLSessionWebSocketTransport()
    let url: URL

    func connect(_ request: WebSocketRequest, options: WebSocket.Options)
      async throws(WebSocketError) -> some WebSocketConnection
    {
      var local = request
      local.url = url
      return try await base.connect(local, options: options)
    }
  }

  @Test(
    "Only an eligible observed 401 refreshes once and renders the new credential",
    arguments: [0, 1, 2])
  func replay(rejections: Int) async throws {
    let server = try WebSocketServer { peer, request in
      let hasNewToken = request.lowercased().contains("authorization: bearer new")
      if rejections == 0 { return }
      if rejections == 2 || !hasNewToken {
        try await peer.send(
          Array(
            "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"fixture\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
              .utf8))
        return
      }
      try await peer.upgrade(request)
      _ = try await peer.frame()
    }
    defer { server.stop() }
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("new")], token: "old")
    let authentication = Authentication(provider: tokens, refresher: tokens)
    let request = WebSocketRequest(
      authentication: authentication, headers: [.authorization: "caller"],
      url: try #require(URL(string: "wss://example.test/socket")))
    let client = WebSocketClient(transport: LoopbackTransport(url: try await server.url()))
    if rejections == 1 {
      let socket = try await client.connect(request)
      socket.cancel()
    } else {
      await #expect { try await client.connect(request) } throws: {
        ($0 as? WebSocketError)?.kind == .handshakeRejected
      }
    }
    #expect(tokens.refreshes == (rejections == 0 ? 0 : 1))
    let requests = server.requests.withLock { $0 }
    #expect(requests.first?.lowercased().contains("authorization: bearer old") == true)
    #expect(requests.allSatisfy { !$0.contains("caller") })
    if rejections != 0 {
      #expect(requests.count == 2)
      #expect(requests.last?.lowercased().contains("authorization: bearer new") == true)
    }
  }
}
#endif
