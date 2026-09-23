#if WebSocketHummingbird && WebSocketPortable
#if os(Linux) || os(macOS)
import HTTPTesting
import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import Testing
import WebSocketCore
import WebSocketHummingbird
import WebSocketPortable
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite(
  "Hummingbird and NIO client interoperability", .serialized,
  .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HummingbirdPortableClientTests {
  @Test("NIO clients exchange messages and closing one leaves another connection usable")
  func independentConnections() async throws {
    let adapter = try HummingbirdWebSocketAdapter()
    let app = Application(
      router: Router(),
      server: .http1WebSocketUpgrade(configuration: .init(ws: adapter.configuration)) {
        _, channel, _ in
        let scope = try await adapter.prepare(channel: channel)
        return .upgrade([:]) { inbound, outbound, _ in
          try await scope.withConnection(inbound: inbound, outbound: outbound) { socket in
            for try await message in socket.messages {
              try await socket.send(message)
            }
          }
        }
      },
      configuration: .init(address: .hostname("localhost", port: 0)))
    try await app.test(.live) { client in
      let port = try #require(client.port)
      let url = try #require(URL(string: "ws://localhost:\(port)/"))
      let transport = try NIOWebSocketTransport()
      do {
        let sockets = WebSocketClient(transport: transport)
        let first = try await sockets.connect(to: url)
        let second = try await sockets.connect(to: url)
        try await first.send("first")
        try await second.send(Data([1, 2, 3]))
        var firstMessages = first.messages.makeAsyncIterator()
        var secondMessages = second.messages.makeAsyncIterator()
        #expect(try await firstMessages.next() == .text("first"))
        #expect(try await secondMessages.next() == .binary(Data([1, 2, 3])))
        first.cancel()
        try await second.send("still open")
        #expect(try await secondMessages.next() == .text("still open"))
        _ = try await second.close()
        let third = try await sockets.connect(to: url)
        try await third.send("third")
        var thirdMessages = third.messages.makeAsyncIterator()
        #expect(try await thirdMessages.next() == .text("third"))
        _ = try await third.close()
        try await transport.shutdown()
      } catch {
        try? await transport.shutdown()
        throw error
      }
    }
  }
}
#endif
#endif
