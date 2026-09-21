#if WebSocketPortable
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOWebSocket
import WebSocketCore

/// Validates response fields before the supported NIO upgrade machinery consumes them.
final class NIOWebSocketHandshake: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = HTTPClientResponsePart
  typealias InboundOut = HTTPClientResponsePart

  private let exchange: NIOWebSocketExchange
  private let protocols: [String]

  init(exchange: NIOWebSocketExchange, protocols: [String]) {
    self.exchange = exchange
    self.protocols = protocols
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if case .head(let head) = unwrapInboundIn(data) {
      var fields = HTTPFields()
      for (name, value) in head.headers {
        if let name = HTTPField.Name(name) { fields.append(HTTPField(name: name, value: value)) }
      }
      let response = HTTPResponse(status: .init(code: Int(head.status.code)), headerFields: fields)
      guard head.status == .switchingProtocols else {
        exchange.fail(WebSocketError(kind: .handshakeRejected, response: response))
        return
      }
      let selected = head.headers["sec-websocket-protocol"]
      guard head.version == .http1_1,
        head.headers[canonicalForm: "connection"].contains(where: { $0.lowercased() == "upgrade" }),
        head.headers["sec-websocket-extensions"].isEmpty,
        selected.isEmpty || (selected.count == 1 && protocols.contains(selected[0]))
      else {
        exchange.fail(WebSocketError(kind: .protocolViolation, response: response))
        return
      }
    }
    context.fireChannelRead(data)
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    let kind: WebSocketError.Kind =
      (error as? HTTPParserError) == .headerOverflow
      ? .bufferOverflow : (error is HTTPParserError ? .protocolViolation : .transport)
    exchange.fail(WebSocketError(kind: kind, underlying: error))
  }
}
#endif
