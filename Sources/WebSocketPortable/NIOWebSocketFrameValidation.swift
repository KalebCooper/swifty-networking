#if WebSocketPortable
import NIOCore
import WebSocketCore

/// Checks canonical wire lengths and server roles that the extension-capable NIO decoder permits.
final class NIOWebSocketFrameValidation: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = ByteBuffer

  private let exchange: NIOWebSocketExchange
  private var header: [UInt8] = []
  private var remaining: UInt64 = 0

  init(exchange: NIOWebSocketExchange) { self.exchange = exchange }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var input = unwrapInboundIn(data)
    while input.readableBytes > 0 {
      if remaining > 0 {
        let consumed = min(remaining, UInt64(input.readableBytes))
        input.moveReaderIndex(forwardBy: Int(consumed))
        remaining -= consumed
        continue
      }
      guard let byte: UInt8 = input.readInteger() else { break }
      header.append(byte)
      if header.count == 1 {
        let opcode = byte & 15
        guard byte & 0x70 == 0, [0, 1, 2, 8, 9, 10].contains(opcode) else {
          exchange.fail(WebSocketError(kind: .protocolViolation))
          return
        }
      }
      guard header.count >= 2 else { continue }
      guard header[1] & 0x80 == 0 else {
        exchange.fail(WebSocketError(kind: .protocolViolation))
        return
      }
      let marker = header[1] & 0x7F
      let needed = marker == 127 ? 10 : (marker == 126 ? 4 : 2)
      guard header.count == needed else { continue }
      let length =
        needed == 2
        ? UInt64(marker) : header.dropFirst(2).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      guard (marker != 126 || length >= 126),
        (marker != 127 || (length >= 65_536 && header[2] & 0x80 == 0))
      else {
        exchange.fail(WebSocketError(kind: .protocolViolation))
        return
      }
      if header[0] & 8 != 0, header[0] & 0x80 == 0 || length > 125 {
        exchange.fail(WebSocketError(kind: .protocolViolation))
        return
      }
      remaining = length
      header.removeAll(keepingCapacity: true)
    }
    context.fireChannelRead(data)
  }
}
#endif
