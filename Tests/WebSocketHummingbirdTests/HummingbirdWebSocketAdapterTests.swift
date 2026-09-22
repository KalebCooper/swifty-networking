#if WebSocketHummingbird
#if os(Linux) || os(macOS)
import HTTPTesting
import Hummingbird
import HummingbirdTesting
import HummingbirdWSClient
import HummingbirdWSTesting
import Testing
import WebSocketCore
import WebSocketHummingbird
#if canImport(Darwin)
import WebSocketURLSession
#endif
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

private enum FixtureFailure: Error {
  case expected
}

@Suite("Hummingbird WebSocket adapter", .serialized, .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HummingbirdWebSocketAdapterTests {
  @Test("A URLSession client exchanges messages with the accepted shared session")
  func appleClient() async throws {
    #if canImport(Darwin)
    let adapter = try HummingbirdWebSocketAdapter()
    let app = echoApplication(adapter: adapter)
    try await app.test(.live) { client in
      let port = try #require(client.port)
      let url = try #require(URL(string: "ws://localhost:\(port)/"))
      let socket = try await WebSocketClient(transport: URLSessionWebSocketTransport())
        .connect(to: url)
      defer { socket.cancel() }
      try await socket.send("apple")
      var messages = socket.messages.makeAsyncIterator()
      #expect(try await messages.next() == .text("apple"))
      _ = try await socket.close()
    }
    #endif
  }

  @Test(
    "Authentication rejects before upgrade and accepted sockets echo through the shared session")
  func authenticatedEcho() async throws {
    let adapter = try HummingbirdWebSocketAdapter()
    let app = echoApplication(adapter: adapter, requiresAuthorization: true)
    try await app.test(.live) { client in
      await #expect(throws: WebSocketClientError.webSocketUpgradeFailed) {
        try await client.ws("/") { inbound, _, _ in
          for try await _ in inbound {}
        }
      }
      let configuration = WebSocketClientConfiguration(
        additionalHeaders: [.authorization: "Bearer fixture"])
      let close = try await client.ws("/", configuration: configuration) {
        inbound, outbound, _ in
        try await outbound.write(.binary(.init(bytes: [1, 2, 3])))
        try await outbound.write(.text("hello"))
        var messages = inbound.messages(maxSize: 64).makeAsyncIterator()
        #expect(try await messages.next() == .binary(.init(bytes: [1, 2, 3])))
        #expect(try await messages.next() == .text("hello"))
        try await outbound.close(.normalClosure, reason: nil)
      }
      #expect(close?.closeCode == .normalClosure)
    }
  }

  @Test("Fragmented messages use the shared size error and close with 1009")
  func fragmentedMessageTooLarge() async throws {
    let adapter = try HummingbirdWebSocketAdapter(options: .init(maxMessageBytes: 4))
    let release = WebSocketCompletion<Void>()
    let app = Application(
      router: Router(),
      server: .http1WebSocketUpgrade(configuration: .init(ws: adapter.configuration)) {
        _, channel, _ in
        let scope = try await adapter.prepare(channel: channel)
        return .upgrade([:]) { inbound, outbound, _ in
          try await scope.withConnection(inbound: inbound, outbound: outbound) { socket in
            do {
              for try await _ in socket.messages {}
              Issue.record("Oversized fragmented message completed")
            } catch { #expect((error as? WebSocketError)?.kind == .messageTooLarge) }
            try await release.wait()
          }
        }
      },
      configuration: .init(address: .hostname("localhost", port: 0)))
    do {
      try await app.test(.live) { client in
        let close = try await client.ws("/") { inbound, outbound, _ in
          try await outbound.write(
            .custom(.init(fin: false, opcode: .text, data: .init(bytes: [65, 66, 67]))))
          try await outbound.write(
            .custom(.init(fin: true, opcode: .continuation, data: .init(bytes: [68, 69]))))
          for try await _ in inbound {}
        }
        #expect(close?.closeCode == .messageTooLarge)
        release.finish(.success(()))
      }
    } catch {
      release.finish(.success(()))
      throw error
    }
  }

  @Test("A handler error releases its channel and leaves the server available")
  func handlerError() async throws {
    let adapter = try HummingbirdWebSocketAdapter()
    let reached = WebSocketRendezvous()
    let app = Application(
      router: Router(),
      server: .http1WebSocketUpgrade(configuration: .init(ws: adapter.configuration)) {
        request, channel, _ in
        let fails = request.path == "/fail"
        let scope = try await adapter.prepare(channel: channel)
        return .upgrade([:]) { inbound, outbound, _ in
          try await scope.withConnection(inbound: inbound, outbound: outbound) { socket in
            if fails {
              reached.arrive()
              throw FixtureFailure.expected
            }
            for try await message in socket.messages {
              try await socket.send(message)
            }
          }
        }
      },
      configuration: .init(address: .hostname("localhost", port: 0)))
    try await app.test(.live) { client in
      _ = try? await client.ws("/fail") { inbound, _, _ in
        for try await _ in inbound {}
      }
      #expect(reached.arrivals == 1)
      _ = try await client.ws("/") { inbound, outbound, _ in
        try await outbound.write(.text("healthy"))
        var messages = inbound.messages(maxSize: 64).makeAsyncIterator()
        #expect(try await messages.next() == .text("healthy"))
        try await outbound.close(.normalClosure, reason: nil)
      }
    }
  }

  @Test("Cancelling one live connection leaves another and the server usable")
  func independentConnections() async throws {
    #if canImport(Darwin)
    let adapter = try HummingbirdWebSocketAdapter()
    let app = echoApplication(adapter: adapter)
    try await app.test(.live) { client in
      let port = try #require(client.port)
      let url = try #require(URL(string: "ws://localhost:\(port)/"))
      let transport = URLSessionWebSocketTransport()
      let sockets = WebSocketClient(transport: transport)
      let first = try await sockets.connect(to: url)
      let second = try await sockets.connect(to: url)
      defer { first.cancel(); second.cancel() }
      try await first.send("first")
      try await second.send("second")
      var firstMessages = first.messages.makeAsyncIterator()
      var secondMessages = second.messages.makeAsyncIterator()
      #expect(try await firstMessages.next() == .text("first"))
      #expect(try await secondMessages.next() == .text("second"))
      first.cancel()
      try await second.send("still open")
      #expect(try await secondMessages.next() == .text("still open"))
      let third = try await sockets.connect(to: url)
      defer { third.cancel() }
      try await third.send("third")
      var thirdMessages = third.messages.makeAsyncIterator()
      #expect(try await thirdMessages.next() == .text("third"))
    }
    #endif
  }

  @Test(
    "Peer private and empty close frames retain their actual metadata", arguments: [false, true])
  func peerClose(empty: Bool) async throws {
    let adapter = try HummingbirdWebSocketAdapter()
    let captured = WebSocketCompletion<WebSocketClose>()
    let app = Application(
      router: Router(),
      server: .http1WebSocketUpgrade(configuration: .init(ws: adapter.configuration)) {
        _, channel, _ in
        let scope = try await adapter.prepare(channel: channel)
        return .upgrade([:]) { inbound, outbound, _ in
          try await scope.withConnection(inbound: inbound, outbound: outbound) { socket in
            for try await _ in socket.messages {}
            captured.finish(.success(socket.closeInfo ?? WebSocketClose()))
          }
        }
      },
      configuration: .init(address: .hostname("localhost", port: 0)))
    try await app.test(.live) { client in
      _ = try await client.ws("/") { inbound, outbound, _ in
        if empty {
          try await outbound.write(
            .custom(.init(fin: true, opcode: .connectionClose, data: .init())))
        } else {
          try await outbound.close(.unknown(4001), reason: "private")
        }
        for try await _ in inbound {}
      }
      let close = try await captured.wait()
      #expect(close.code?.rawValue == (empty ? nil : 4001))
      #expect(close.reason == (empty ? nil : "private"))
    }
  }

  @Test("Ping waits for a correlated pong while the accepted reader runs")
  func ping() async throws {
    let adapter = try HummingbirdWebSocketAdapter()
    let app = Application(
      router: Router(),
      server: .http1WebSocketUpgrade(configuration: .init(ws: adapter.configuration)) {
        _, channel, _ in
        let scope = try await adapter.prepare(channel: channel)
        return .upgrade([:]) { inbound, outbound, _ in
          try await scope.withConnection(inbound: inbound, outbound: outbound) { socket in
            try await socket.ping()
            try await socket.send("pong observed")
          }
        }
      },
      configuration: .init(address: .hostname("localhost", port: 0)))
    try await app.test(.live) { client in
      _ = try await client.ws("/") { inbound, _, _ in
        var messages = inbound.messages(maxSize: 64).makeAsyncIterator()
        let reply = try await messages.next()
        #expect(reply == .text("pong observed"))
      }
    }
  }

  @Test("Enqueue order and both admission failure policies use the shared session")
  func sendPolicies() async throws {
    let options = WebSocket.Options(
      maxMessageBytes: 4, maxPendingSendBytes: 8, maxPendingSendMessages: 2)
    let adapter = try HummingbirdWebSocketAdapter(options: options)
    let received = WebSocketRendezvous()
    let serverFinished = WebSocketRendezvous()
    let app = Application(
      router: Router(),
      server: .http1WebSocketUpgrade(configuration: .init(ws: adapter.configuration)) {
        _, channel, _ in
        let scope = try await adapter.prepare(channel: channel)
        return .upgrade([:]) { inbound, outbound, _ in
          try await scope.withConnection(inbound: inbound, outbound: outbound) { socket in
            let first = try socket.enqueue("one")
            let second = try socket.enqueue("two")
            try await first.wait()
            try await second.wait()
            do {
              _ = try socket.enqueue("large", failurePolicy: .preserveIfUnsent)
              Issue.record("Oversized send was admitted")
            } catch { #expect((error as? WebSocketError)?.kind == .messageTooLarge) }
            try await socket.send("ok")
            do {
              _ = try socket.enqueue("large", failurePolicy: .abortConnection)
              Issue.record("Dependent oversized send was admitted")
            } catch { #expect((error as? WebSocketError)?.kind == .messageTooLarge) }
            serverFinished.arrive()
          }
        }
      },
      configuration: .init(address: .hostname("localhost", port: 0)))
    try await app.test(.live) { client in
      _ = try? await client.ws("/") { inbound, _, _ in
        var messages = inbound.messages(maxSize: 16).makeAsyncIterator()
        let first = try await messages.next()
        let second = try await messages.next()
        let third = try await messages.next()
        #expect(first == .text("one"))
        #expect(second == .text("two"))
        #expect(third == .text("ok"))
        received.arrive()
      }
      #expect(received.arrivals == 1)
      #expect(serverFinished.arrivals == 1)
    }
  }

  @Test("Hummingbird shutdown cancels an active handler and settles its escaped socket")
  func serverShutdown() async throws {
    let adapter = try HummingbirdWebSocketAdapter()
    let accepted = WebSocketCompletion<WebSocket>()
    let clientFinished = WebSocketCompletion<Void>()
    let app = Application(
      router: Router(),
      server: .http1WebSocketUpgrade(configuration: .init(ws: adapter.configuration)) {
        _, channel, _ in
        let scope = try await adapter.prepare(channel: channel)
        return .upgrade([:]) { inbound, outbound, _ in
          try await scope.withConnection(inbound: inbound, outbound: outbound) { socket in
            accepted.finish(.success(socket))
            for try await _ in socket.messages {}
          }
        }
      },
      configuration: .init(address: .hostname("localhost", port: 0)))
    try await app.test(.live) { client in
      Task {
        _ = try? await client.ws("/") { inbound, _, _ in
          for try await _ in inbound {}
        }
        clientFinished.finish(.success(()))
      }
      _ = try await accepted.wait()
    }
    try await clientFinished.wait()
    let socket = try await accepted.wait()
    await #expect(throws: WebSocketError.self) { try await socket.send("after shutdown") }
  }

  @Test("A stalled application reader reaches the shared bounded inbox policy")
  func stalledReaderOverflow() async throws {
    let options = WebSocket.Options(
      maxBufferedBytes: 4, maxBufferedMessages: 1, maxMessageBytes: 4,
      maxPendingSendBytes: 4)
    let adapter = try HummingbirdWebSocketAdapter(options: options)
    let release = WebSocketCompletion<Void>()
    let app = Application(
      router: Router(),
      server: .http1WebSocketUpgrade(configuration: .init(ws: adapter.configuration)) {
        _, channel, _ in
        let scope = try await adapter.prepare(channel: channel)
        return .upgrade([:]) { inbound, outbound, _ in
          try await scope.withConnection(inbound: inbound, outbound: outbound) { socket in
            var messages = socket.messages.makeAsyncIterator()
            _ = try await messages.next()
            try await release.wait()
          }
        }
      },
      configuration: .init(address: .hostname("localhost", port: 0)))
    do {
      try await app.test(.live) { client in
        let close = try await client.ws("/") { inbound, outbound, _ in
          try await outbound.write(.text("a"))
          try await outbound.write(.text("b"))
          try await outbound.write(.text("c"))
          for try await _ in inbound {}
        }
        #expect(close?.closeCode == .policyViolation)
        release.finish(.success(()))
      }
    } catch {
      release.finish(.success(()))
      throw error
    }
  }

  private func echoApplication(
    adapter: HummingbirdWebSocketAdapter, requiresAuthorization: Bool = false
  ) -> Application<RouterResponder<BasicRequestContext>> {
    Application(
      router: Router(),
      server: .http1WebSocketUpgrade(configuration: .init(ws: adapter.configuration)) {
        request, channel, _ in
        guard
          !requiresAuthorization
            || request.headerFields[.authorization] == "Bearer fixture"
        else { return .dontUpgrade }
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
  }
}
#endif
#endif
