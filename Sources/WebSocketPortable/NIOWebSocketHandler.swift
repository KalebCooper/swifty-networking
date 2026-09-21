#if WebSocketPortable
import NIOCore
import NIOWebSocket
import WebSocketCore
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// RFC framing state, confined to the channel's event loop.
final class NIOWebSocketHandler: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame

  private var accumulated = ByteBuffer()
  private let exchange: NIOWebSocketExchange
  private var fragments = 0
  private let maximum: Int
  private var opcode: WebSocketOpcode?

  init(exchange: NIOWebSocketExchange, maximum: Int) {
    self.exchange = exchange
    self.maximum = maximum
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    do throws(WebSocketError) {
      guard frame.maskKey == nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else {
        throw WebSocketError(kind: .protocolViolation)
      }
      switch frame.opcode {
      case .connectionClose:
        exchange.peerClosed(try close(frame.data), payload: frame.data)
      case .ping:
        exchange.write(opcode: .pong, payload: frame.data).whenFailure { [exchange] in
          exchange.fail(NIOWebSocketExchange.error($0))
        }
      case .pong: exchange.pong(frame.data)
      case .binary, .text, .continuation:
        try accept(frame)
      default: throw WebSocketError(kind: .protocolViolation)
      }
    } catch { exchange.fail(error) }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    exchange.fail(NIOWebSocketExchange.error(error))
  }

  private func accept(_ frame: WebSocketFrame) throws(WebSocketError) {
    if frame.opcode == .continuation {
      guard opcode != nil else { throw WebSocketError(kind: .protocolViolation) }
    } else {
      guard opcode == nil else { throw WebSocketError(kind: .protocolViolation) }
      opcode = frame.opcode
    }
    guard fragments < 1_024 else { throw WebSocketError(kind: .bufferOverflow) }
    guard frame.data.readableBytes <= maximum - accumulated.readableBytes else {
      throw WebSocketError(kind: .messageTooLarge)
    }
    fragments += 1
    accumulated.writeImmutableBuffer(frame.data)
    guard frame.fin else { return }
    let message: WebSocket.Message
    if opcode == .text {
      guard let text = String(bytes: accumulated.readableBytesView, encoding: .utf8) else {
        throw WebSocketError(kind: .protocolViolation)
      }
      message = .text(text)
    } else {
      message = .binary(Data(accumulated.readableBytesView))
    }
    accumulated = ByteBuffer()
    fragments = 0
    opcode = nil
    exchange.inbox.offer(message)
  }

  private func close(_ payload: ByteBuffer) throws(WebSocketError) -> WebSocketClose {
    guard payload.readableBytes > 0 else { return WebSocketClose() }
    var payload = payload
    guard let code: UInt16 = payload.readInteger(),
      ((1000...1014).contains(code) && ![1004, 1005, 1006, 1010].contains(code))
        || (3000...4999).contains(code),
      let reason = String(bytes: payload.readableBytesView, encoding: .utf8)
    else { throw WebSocketError(kind: .protocolViolation) }
    return WebSocketClose(code: .init(rawValue: code), reason: reason.isEmpty ? nil : reason)
  }
}
#endif
