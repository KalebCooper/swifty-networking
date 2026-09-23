#if WebSocketPortable
import HTTPTesting
import NIOCore
import NIOSSL
import Testing
import WebSocketCore
@testable import WebSocketPortable
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite("NIO WebSocket transport", .serialized, .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct NIOWebSocketTransportTests {
  @Test(
    "Opening head size and field count limits fail as resource errors",
    arguments: [
      "HTTP/1.1 101 " + String(repeating: "x", count: 16_384),
      "HTTP/1.1 101 Switching Protocols\r\n" + String(repeating: "X: y\r\n", count: 101) + "\r\n",
    ])
  func boundedOpeningHead(response: String) async throws {
    let server = RawWebSocketServer()
    let transport = try transport()
    do {
      try await server.start(response: response)
      do {
        _ = try await WebSocketClient(transport: transport).connect(to: url(server))
        Issue.record("An oversized opening head succeeded")
      } catch { #expect((error as? WebSocketError)?.kind == .bufferOverflow) }
      try await transport.shutdown()
      #expect(transport.connectionCount == 0)
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  @Test("A cancelled opening closes its physical channel and leaves the transport reusable")
  func cancelledOpening() async throws {
    let server = RawWebSocketServer()
    let transport = try transport()
    do {
      try await server.start(response: nil)
      let address = try url(server)
      let connect = Task { try await WebSocketClient(transport: transport).connect(to: address) }
      _ = try await server.head.wait()
      connect.cancel()
      do { _ = try await connect.value; Issue.record("Cancelled opening succeeded") } catch {
        #expect((error as? WebSocketError)?.kind == .cancelled)
      }
      try await server.closed.wait()
      let healthy = RawWebSocketServer()
      do {
        try await healthy.start(initial: [0x81, 1, 0x78])
        let socket = try await WebSocketClient(transport: transport).connect(to: url(healthy))
        var iterator = socket.messages.makeAsyncIterator()
        #expect(try await iterator.next() == .text("x"))
        socket.cancel()
        try await transport.shutdown()
        try await healthy.stop()
      } catch { try? await healthy.stop(); throw error }
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  @Test("Cancelling during a real TLS handshake closes the pending channel")
  func cancelTLSHandshake() async throws {
    let server = RawWebSocketServer()
    let transport = try transport()
    do {
      try await server.start(response: nil)
      let address = try url(server, tls: true)
      let connect = Task { try await WebSocketClient(transport: transport).connect(to: address) }
      _ = try await server.accepted.wait()
      connect.cancel()
      do { _ = try await connect.value; Issue.record("A cancelled TLS handshake succeeded") } catch
      { #expect((error as? WebSocketError)?.kind == .cancelled) }
      try await transport.shutdown()
      #expect(transport.connectionCount == 0)
      try await server.closed.wait()
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  @Test("An injected close deadline aborts a peer that withholds its reply")
  func closeDeadline() async throws {
    let server = RawWebSocketServer()
    let transport = try transport()
    let clock = RecordingClock()
    do {
      try await server.start()
      let socket = try await WebSocketClient(clock: clock, transport: transport).connect(
        to: url(server))
      let close = Task { try await socket.close() }
      var frames = server.frames.makeAsyncIterator()
      let frame = try #require(await frames.next())
      #expect(frame[0] == 0x88)
      await clock.waitForPendingSleep()
      clock.advance(by: .seconds(5))
      do { _ = try await close.value; Issue.record("An unanswered close succeeded") } catch {
        #expect((error as? WebSocketError)?.kind == .timedOut)
      }
      try await server.closed.wait()
      try await transport.shutdown()
      #expect(transport.connectionCount == 0)
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  @Test("A close answered by a TLS peer returns before the peer answers the closure alert")
  func closeAnsweredOverTLS() async throws {
    let server = RawWebSocketServer()
    let transport = try transport()
    do {
      try await server.start(tls: true)
      let socket = try await WebSocketClient(clock: RecordingClock(), transport: transport)
        .connect(to: url(server, tls: true))
      let close = Task { try await socket.close() }
      var frames = server.frames.makeAsyncIterator()
      let frame = try #require(await frames.next())
      #expect(frame[0] == 0x88)
      // The peer stops reading, so the closure alert the client sends next is never answered,
      // which is how a server that drops the connection without one looks to the client.
      let peer = try await server.accepted.wait()
      try await peer.setOption(ChannelOptions.autoRead, value: false).get()
      try await peer.writeAndFlush(ByteBuffer(bytes: [0x88, 2, 0x03, 0xE8])).get()
      #expect(try await close.value.code == .normalClosure)
      #expect(transport.connectionCount == 1)
      try await peer.setOption(ChannelOptions.autoRead, value: true).get()
      try await server.closed.wait()
      try await transport.shutdown()
      #expect(transport.connectionCount == 0)
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  @Test("Closing one connection and releasing its last owner leaves another connection usable")
  func independentOwners() async throws {
    let first = RawWebSocketServer()
    let second = RawWebSocketServer()
    let transport = try transport()
    do {
      try await first.start()
      try await second.start()
      let client = WebSocketClient(transport: transport)
      var socket: WebSocket? = try await client.connect(to: url(first))
      var messages: WebSocketMessages? = socket?.messages
      socket = nil
      let peer = try await first.accepted.wait()
      try await peer.writeAndFlush(ByteBuffer(bytes: [0x81, 1, 0x78])).get()
      do {
        var iterator = try #require(messages).makeAsyncIterator()
        #expect(try await iterator.next() == .text("x"))
      }
      let healthy = try await client.connect(to: url(second))
      messages = nil
      try await first.closed.wait()
      let otherPeer = try await second.accepted.wait()
      try await otherPeer.writeAndFlush(ByteBuffer(bytes: [0x81, 1, 0x79])).get()
      var iterator = healthy.messages.makeAsyncIterator()
      #expect(try await iterator.next() == .text("y"))
      healthy.cancel()
      try await second.closed.wait()
      try await transport.shutdown()
      #expect(transport.connectionCount == 0)
      try await first.stop()
      try await second.stop()
    } catch {
      try? await transport.shutdown()
      try? await first.stop()
      try? await second.stop()
      throw error
    }
  }

  @Test(
    "Bad accept values and unsolicited negotiation fail as protocol errors",
    arguments: [
      RawWebSocketServer.upgrade.replacingOccurrences(
        of: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", with: "bad"),
      RawWebSocketServer.upgrade.replacingOccurrences(of: "Connection: Upgrade\r\n", with: ""),
      RawWebSocketServer.upgrade.replacingOccurrences(
        of: "\r\n\r\n", with: "\r\nSec-WebSocket-Protocol: unknown\r\n\r\n"),
      RawWebSocketServer.upgrade.replacingOccurrences(
        of: "\r\n\r\n", with: "\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"),
    ])
  func invalidUpgrade(response: String) async throws {
    let server = RawWebSocketServer()
    let transport = try transport()
    do {
      try await server.start(response: response)
      do {
        _ = try await WebSocketClient(transport: transport).connect(to: url(server))
        Issue.record("Invalid upgrade succeeded")
      } catch { #expect((error as? WebSocketError)?.kind == .protocolViolation) }
      try await transport.shutdown()
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  @Test(
    "Plaintext and verified TLS exchange literal messages and release every channel",
    arguments: [false, true])
  func loopbackExchange(tls: Bool) async throws {
    let server = RawWebSocketServer()
    let transport = try transport()
    do {
      try await server.start(initial: [0x81, 2, 0x68, 0x69, 0x82, 2, 1, 2], tls: tls)
      let client = WebSocketClient(transport: transport)
      let socket = try await client.connect(to: url(server, tls: tls))
      var iterator = socket.messages.makeAsyncIterator()
      #expect(try await iterator.next() == .text("hi"))
      #expect(try await iterator.next() == .binary(Data([1, 2])))
      let first = try socket.enqueue("first")
      let second = try socket.enqueue(Data([3, 4]))
      try await first.wait()
      try await second.wait()
      let head = try await server.head.wait()
      #expect(head.hasPrefix("GET /a%2Fb?q=%2B HTTP/1.1\r\n"))
      #expect(head.contains("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="))
      let channel = try await server.accepted.wait()
      try await channel.writeAndFlush(ByteBuffer(bytes: [0x88, 3, 0x0F, 0xA1, 0x78])).get()
      #expect(try await iterator.next() == nil)
      #expect(socket.closeInfo == WebSocketClose(code: .init(rawValue: 4001), reason: "x"))
      try await transport.shutdown()
      try await server.closed.wait()
      try await transport.shutdown()
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  @Test("Cancelling after a real partial frame aborts the channel and releases the active write")
  func partialWriteCancellation() async throws {
    let server = RawWebSocketServer()
    let transport = try transport()
    do {
      try await server.start()
      let socket = try await WebSocketClient(transport: transport).connect(to: url(server))
      let channel = try #require(transport.channels.first)
      try await channel.eventLoop.submit {
        try channel.pipeline.syncOperations.addHandler(PartialWriteHandler(), position: .first)
      }.get()
      let send = Task { try await socket.send("abcd") }
      let prefix = try await server.prefix.wait()
      #expect(prefix.count == 8)
      #expect(prefix[0] == 0x81)
      #expect(prefix[1] == 0x84)
      send.cancel()
      do {
        try await send.value; Issue.record("A partial write succeeded after cancellation")
      } catch { #expect((error as? WebSocketError)?.kind == .cancelled) }
      try await server.closed.wait()
      try await transport.shutdown()
      #expect(transport.connectionCount == 0)
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  @Test(
    "A cancelled ping waiter accepts its late pong and a new probe while messages remain unread")
  func pingRecovery() async throws {
    let server = RawWebSocketServer()
    let transport = try transport()
    do {
      try await server.start(initial: [0x81, 1, 0x78])
      let socket = try await transport.connect(WebSocketRequest(url: url(server)), options: .init())
      let channel = try await server.accepted.wait()
      var frames = server.frames.makeAsyncIterator()
      let first = Task { try await socket.ping() }
      let frame = try #require(await frames.next())
      #expect(frame[0] == 0x89)
      let payload = (0..<8).map { frame[6 + $0] ^ frame[2 + $0 % 4] }
      first.cancel()
      do { try await first.value; Issue.record("Cancelled ping waiter succeeded") } catch {
        #expect((error as? WebSocketError)?.kind == .cancelled)
      }
      try await channel.writeAndFlush(ByteBuffer(bytes: [0x8A, 8] + payload)).get()
      // A subsequent data message proves the pong was processed on the same inbound event loop.
      try await channel.writeAndFlush(ByteBuffer(bytes: [0x81, 1, 0x79])).get()
      #expect(try await socket.receive() == .text("x"))
      #expect(try await socket.receive() == .text("y"))
      let second = Task { try await socket.ping() }
      let next = try #require(await frames.next())
      let nextPayload = (0..<8).map { next[6 + $0] ^ next[2 + $0 % 4] }
      #expect(nextPayload != payload)
      try await channel.writeAndFlush(ByteBuffer(bytes: [0x8A, 8] + nextPayload)).get()
      try await second.value
      socket.cancel()
      try await transport.shutdown()
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  @Test("HTTP refusals preserve actual status without following redirects", arguments: [401, 307])
  func refusedUpgrade(status: Int) async throws {
    let server = RawWebSocketServer()
    let transport = try transport()
    do {
      try await server.start(
        response:
          "HTTP/1.1 \(status) Refused\r\nLocation: /elsewhere\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\n\r\n"
      )
      do {
        _ = try await WebSocketClient(transport: transport).connect(to: url(server))
        Issue.record("Rejected upgrade succeeded")
      } catch {
        #expect((error as? WebSocketError)?.kind == .handshakeRejected)
        #expect((error as? WebSocketError)?.response?.status.code == status)
      }
      try await transport.shutdown()
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  @Test(
    "TLS rejects an untrusted certificate and a trusted certificate for the wrong hostname",
    arguments: [false, true])
  func rejectedTLS(mismatch: Bool) async throws {
    let server = RawWebSocketServer()
    let transport = try NIOWebSocketTransport(
      configuration: mismatch ? TLSFixture.client() : .makeClientConfiguration(),
      keySource: { "dGhlIHNhbXBsZSBub25jZQ==" })
    do {
      try await server.start(tls: true)
      do {
        _ = try await WebSocketClient(transport: transport).connect(
          to: url(server, host: mismatch ? "127.0.0.1" : "localhost", tls: true))
        Issue.record("TLS verification unexpectedly succeeded")
      } catch { #expect((error as? WebSocketError)?.kind == .transport) }
      try await transport.shutdown()
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  @Test("Shutdown races a held upgrade and repeated callers await complete release")
  func simultaneousShutdown() async throws {
    let server = RawWebSocketServer()
    let transport = try transport()
    do {
      try await server.start(response: nil)
      let address = try url(server)
      let connect = Task { try await WebSocketClient(transport: transport).connect(to: address) }
      _ = try await server.head.wait()
      async let first: Void = transport.shutdown()
      async let second: Void = transport.shutdown()
      try await first
      try await second
      do { _ = try await connect.value; Issue.record("Shutdown allowed opening") } catch {
        #expect((error as? WebSocketError)?.kind == .cancelled)
      }
      try await server.closed.wait()
      do {
        _ = try await WebSocketClient(transport: transport).connect(to: address)
        Issue.record("Shutdown accepted another connection")
      } catch { #expect(error.kind == .closed) }
      try await server.stop()
    } catch {
      try? await transport.shutdown()
      try? await server.stop()
      throw error
    }
  }

  private func transport() throws -> NIOWebSocketTransport {
    try NIOWebSocketTransport(
      configuration: TLSFixture.client(), keySource: { "dGhlIHNhbXBsZSBub25jZQ==" })
  }

  private func url(_ server: RawWebSocketServer, host: String = "localhost", tls: Bool = false)
    throws -> URL
  {
    try #require(URL(string: "\(tls ? "wss" : "ws")://\(host):\(server.port)/a%2Fb?q=%2B"))
  }
}
#endif
