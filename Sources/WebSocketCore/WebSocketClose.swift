/// Close metadata reported by a peer.
///
/// This value does not imply that a close handshake completed successfully.
public struct WebSocketClose: Equatable, Sendable {
  /// The raw peer code, or nil when the peer supplied no code.
  public let code: WebSocket.CloseCode?

  /// The peer's optional reason, which may contain sensitive application data.
  public let reason: String?

  /// Creates close metadata without inferring a code for an empty close payload.
  public init(code: WebSocket.CloseCode? = nil, reason: String? = nil) {
    self.code = code
    self.reason = reason
  }
}
