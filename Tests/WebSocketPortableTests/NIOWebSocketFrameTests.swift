#if WebSocketPortable
import HTTPTesting
import NIOCore
import NIOEmbedded
import NIOWebSocket
import Synchronization
import Testing
import WebSocketCore
@testable import WebSocketPortable

@Suite("NIO WebSocket framing", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct NIOWebSocketFrameTests {
  @Test("Abrupt channel closure fails instead of inventing a normal close")
  func abruptClosure() async throws {
    let (channel, exchange) = try fixture()
    _ = try channel.finish()
    channel.embeddedEventLoop.run()
    do {
      _ = try await exchange.inbox.next(reader: ObjectIdentifier(exchange))
      Issue.record("Abrupt closure succeeded")
    } catch { #expect(error.kind == .transport) }
    #expect(exchange.closeInfo == nil)
  }

  @Test("Raw and empty close payloads retain their exact metadata", arguments: [false, true])
  func closeMetadata(empty: Bool) async throws {
    let (channel, exchange) = try fixture()
    defer { _ = try? channel.finish() }
    try channel.writeInbound(ByteBuffer(bytes: empty ? [0x88, 0] : [0x88, 3, 0x0F, 0xA1, 0x78]))
    channel.embeddedEventLoop.run()
    #expect(
      exchange.closeInfo
        == (empty ? WebSocketClose() : WebSocketClose(code: .init(rawValue: 4001), reason: "x")))
    #expect(try await exchange.inbox.next(reader: ObjectIdentifier(exchange)) == nil)
  }

  @Test("Control violations remain protocol errors under a small message limit")
  func controlLengthClassification() async throws {
    let (channel, exchange) = try fixture(maximum: 4)
    defer { _ = try? channel.finish() }
    try channel.writeInbound(ByteBuffer(bytes: [0x89, 126, 0, 126]))
    do {
      _ = try await exchange.inbox.next(reader: ObjectIdentifier(exchange))
      Issue.record("An oversized control frame succeeded")
    } catch { #expect(error.kind == .protocolViolation) }
  }

  @Test("A finite fragment budget bounds empty fragmented messages")
  func fragmentBudget() async throws {
    let (channel, exchange) = try fixture()
    defer { _ = try? channel.finish() }
    let bytes: [UInt8] = [0x01, 0] + Array(repeating: [UInt8(0), 0], count: 1_024).flatMap { $0 }
    try channel.writeInbound(ByteBuffer(bytes: bytes))
    do {
      _ = try await exchange.inbox.next(reader: ObjectIdentifier(exchange))
      Issue.record("Excessive fragments succeeded")
    } catch { #expect(error.kind == .bufferOverflow) }
  }

  @Test("Every outbound frame obtains a fresh masking draw")
  func freshMaskDraws() throws {
    let draws = Mutex(UInt8(0))
    let (channel, exchange) = try fixture(mask: {
      let byte = draws.withLock { value in
        value += 1; return value
      }
      return [byte, 0, 0, 0]
    })
    defer { _ = try? channel.finish() }
    _ = exchange.write(opcode: .text, payload: ByteBuffer(string: "a"))
    _ = exchange.write(opcode: .binary, payload: ByteBuffer(bytes: [0x62]))
    var output: [UInt8] = []
    while let buffer = try channel.readOutbound(as: ByteBuffer.self) {
      output += buffer.readableBytesView
    }
    #expect(output == [0x81, 0x81, 1, 0, 0, 0, 0x60, 0x82, 0x81, 2, 0, 0, 0, 0x60])
    #expect(draws.withLock { $0 } == 2)
  }

  @Test(
    "Literal malformed frames fail with protocol errors",
    arguments: [
      [0x81, 0x80, 1, 2, 3, 4],
      [0xC1, 0],
      [0x83, 0],
      [0x80, 0],
      [0x09, 0],
      [0x89, 126, 0, 126],
      [0x88, 1, 0],
      [0x88, 2, 3, 237],
      [0x88, 2, 3, 242],
      [0x88, 3, 3, 232, 255],
      [0x81, 1, 255],
      [0x82, 126, 0, 1, 0],
      [0x82, 127, 0, 0, 0, 0, 0, 0, 0, 1, 0],
      [0x82, 127, 128, 0, 0, 0, 0, 0, 0, 0],
      [0x01, 0, 0x81, 0],
    ] as [[UInt8]])
  func malformedFramesFail(_ bytes: [UInt8]) async throws {
    let (channel, exchange) = try fixture()
    defer { _ = try? channel.finish() }
    try channel.writeInbound(ByteBuffer(bytes: bytes))
    do {
      _ = try await exchange.inbox.next(reader: ObjectIdentifier(exchange))
      Issue.record("Malformed frame succeeded")
    } catch { #expect(error.kind == .protocolViolation) }
  }

  @Test(
    "Physical and accumulated oversize messages have resource errors",
    arguments: [
      [0x82, 5, 0, 0, 0, 0, 0],
      [0x02, 3, 0, 0, 0, 0x80, 2, 0, 0],
      [0x82, 126, 0, 126],
    ] as [[UInt8]])
  func oversizedMessages(_ bytes: [UInt8]) async throws {
    let (channel, exchange) = try fixture(maximum: 4)
    defer { _ = try? channel.finish() }
    try channel.writeInbound(ByteBuffer(bytes: bytes))
    do {
      _ = try await exchange.inbox.next(reader: ObjectIdentifier(exchange))
      Issue.record("Oversized frame succeeded")
    } catch { #expect(error.kind == .messageTooLarge) }
  }

  @Test("Split UTF-8 survives an interleaved ping and the pong echoes its payload")
  func splitTextAndControl() async throws {
    let draws = Mutex(0)
    let (channel, exchange) = try fixture(mask: {
      draws.withLock { $0 += 1 }
      return [1, 2, 3, 4]
    })
    defer { _ = try? channel.finish() }
    try channel.writeInbound(
      ByteBuffer(bytes: [0x01, 1, 0xE2, 0x89, 1, 0x78, 0x80, 2, 0x82, 0xAC]))
    #expect(try await exchange.inbox.next(reader: ObjectIdentifier(exchange)) == .text("€"))
    var output: [UInt8] = []
    while let buffer = try channel.readOutbound(as: ByteBuffer.self) {
      output += buffer.readableBytesView
    }
    #expect(output == [0x8A, 0x81, 1, 2, 3, 4, 0x79])
    #expect(draws.withLock { $0 } == 1)
  }

  private func fixture(
    mask: @escaping @Sendable () -> WebSocketMaskingKey = { [1, 2, 3, 4] },
    maximum: Int = 128
  ) throws -> (EmbeddedChannel, NIOWebSocketExchange) {
    let exchange = NIOWebSocketExchange(mask: mask, options: .init(maxMessageBytes: maximum))
    let channel = EmbeddedChannel()
    try channel.pipeline.syncOperations.addHandlers(
      WebSocketFrameEncoder(), NIOWebSocketFrameValidation(exchange: exchange),
      ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: max(maximum, 125))),
      NIOWebSocketHandler(exchange: exchange, maximum: maximum))
    exchange.attach(channel)
    return (channel, exchange)
  }
}
#endif
