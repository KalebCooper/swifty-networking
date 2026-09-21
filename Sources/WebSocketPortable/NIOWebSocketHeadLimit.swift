#if WebSocketPortable
import NIOCore
import WebSocketCore

/// Bounds the entire opening head, including an unterminated status line.
final class NIOWebSocketHeadLimit: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = ByteBuffer

  private var count = 0
  private let exchange: NIOWebSocketExchange
  private var finished = false
  private var suffix: UInt32 = 0

  init(exchange: NIOWebSocketExchange) { self.exchange = exchange }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if !finished {
      for byte in unwrapInboundIn(data).readableBytesView {
        count += 1
        guard count <= 16_384 else {
          exchange.fail(WebSocketError(kind: .bufferOverflow))
          return
        }
        suffix = (suffix << 8) | UInt32(byte)
        if suffix == 0x0D0A0D0A { finished = true; break }
      }
    }
    context.fireChannelRead(data)
  }
}
#endif
