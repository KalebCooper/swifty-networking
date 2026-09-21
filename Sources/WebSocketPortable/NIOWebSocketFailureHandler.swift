#if WebSocketPortable
import NIOCore
import NIOHTTP1
import WebSocketCore

/// Settles upgrade and transport errors that travel past the HTTP handlers.
final class NIOWebSocketFailureHandler: ChannelInboundHandler {
  typealias InboundIn = NIOAny

  private let exchange: NIOWebSocketExchange

  init(exchange: NIOWebSocketExchange) { self.exchange = exchange }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    if error is NIOHTTPClientUpgradeError {
      exchange.fail(WebSocketError(kind: .protocolViolation, underlying: error))
    } else {
      exchange.fail(NIOWebSocketExchange.error(error))
    }
  }
}
#endif
