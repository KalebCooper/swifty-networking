/// An explicitly owned connection with one recoverable message reader.
///
/// The handle, messages value and iterators keep the connection alive. Releasing the last of
/// these owners aborts it. Internal receive and timer tasks do not extend external ownership.
public final class WebSocket: Sendable {
  private let owner: WebSocketOwner

  init(session: WebSocketSession) {
    owner = WebSocketOwner(session: session)
    session.start()
  }

  /// The observed peer close, preserving absent codes and application-defined codes.
  public var closeInfo: WebSocketClose? { owner.session.closeInfo }
  /// A lazy reader view of the connection's existing receive pump.
  public var messages: WebSocketMessages { WebSocketMessages(owner: owner) }
  /// The protocol negotiated during the upgrade.
  public var negotiatedSubprotocol: String? { owner.session.negotiatedSubprotocol }

  /// Aborts this connection and releases pending operations. Repeated calls have no effect.
  public func cancel() { owner.session.cancel() }

  /// Sends one ping and waits for its pong within the captured pingTimeout.
  ///
  /// Overlap throws concurrentOperation. Cancellation before admission sends nothing; after
  /// admission it releases only this caller. The physical probe keeps its original deadline.
  /// Missing that deadline terminates the connection with timedOut, even after caller cancellation.
  public func ping() async throws(WebSocketError) { try await owner.session.ping() }
}

/// Only consumer-facing values retain this token; pump and timer tasks retain the session directly.
final class WebSocketOwner: Sendable {
  let session: WebSocketSession

  init(session: WebSocketSession) { self.session = session }

  deinit { session.cancel() }
}
