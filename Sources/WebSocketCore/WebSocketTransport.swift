/// Establishes backend connections for a WebSocketClient.
///
/// The client supplies a validated request with rendered credentials and no Authentication value.
/// Attempt only that URL, refuse redirects, and report actual pre-upgrade response metadata when
/// available. Enforce maxMessageBytes while assembling messages, before unbounded allocation.
/// Cancellation aborts the attempt; do not reconnect or replay internally.
public protocol WebSocketTransport: Sendable {
  /// The backend connection returned by this transport.
  associatedtype Connection: WebSocketConnection

  /// Performs one upgrade attempt using the supplied request and captured configuration.
  func connect(_ request: WebSocketRequest, options: WebSocket.Options)
    async throws(WebSocketError) -> Connection
}
