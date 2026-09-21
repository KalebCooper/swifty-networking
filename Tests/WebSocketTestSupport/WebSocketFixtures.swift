import WebSocketCore

/// Literal inputs shared by the WebSocket foundation suites.
package enum WebSocketFixtures {
  package static let messages: [WebSocket.Message] = [
    .binary(.init([0, 127, 255])), .text("hello"), .text("é🐕"), .binary(.init()), .text(""),
  ]
}
