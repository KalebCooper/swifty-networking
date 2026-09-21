/// Closure metadata reported by a backend.
///
/// This value does not prove peer acknowledgement or a completed wire close handshake.
/// For a locally initiated close, a backend may report the requested code and reason.
public struct WebSocketClose: Equatable, Sendable {
  /// The reported raw code, or nil when no code was supplied.
  public let code: WebSocket.CloseCode?

  /// The reported optional reason, which may contain sensitive application data.
  public let reason: String?

  /// Creates close metadata without inferring a code for an empty close payload.
  public init(code: WebSocket.CloseCode? = nil, reason: String? = nil) {
    self.code = code
    self.reason = reason
  }
}
