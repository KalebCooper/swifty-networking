/// A backend's upgraded connection, used by the shared lifecycle.
///
/// Receive yields complete messages; nil means a valid peer close and closeInfo must already
/// be available. Abrupt EOF and protocol failures throw. Ping completes only for its pong.
/// Cancellation must promptly stop backend work and release resources; subsequent operations
/// must fail without restarting it. Implementations must
/// permit receive and control operations concurrently, without adding application queues.
public protocol WebSocketConnection: Sendable {
  /// Peer close metadata, available before receive ends normally.
  var closeInfo: WebSocketClose? { get }
  /// The protocol selected by the peer, if any.
  var negotiatedSubprotocol: String? { get }

  /// Aborts this connection synchronously and idempotently.
  func cancel()
  /// Attempts a close handshake, returning the peer's metadata.
  ///
  /// The shared caller supplies validated arguments and bounds the operation with a deadline.
  func close(code: WebSocket.CloseCode, reason: String?)
    async throws(WebSocketError) -> WebSocketClose
  /// Sends one ping and waits for its corresponding pong.
  func ping() async throws(WebSocketError)
  /// Receives one complete application message, or nil after a valid peer close.
  func receive() async throws(WebSocketError) -> WebSocket.Message?
  /// Writes one complete message without reporting application delivery.
  func send(_ message: WebSocket.Message) async throws(WebSocketError)
}
