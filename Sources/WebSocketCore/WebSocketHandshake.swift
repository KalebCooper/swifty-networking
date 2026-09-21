import HTTPCore
import HTTPTypes

/// The shared outbound handshake policy, independent of connection lifecycle operations.
package enum WebSocketHandshake {
  /// Validates inputs, obtains credentials and permits one known-401 replay within one deadline.
  ///
  /// The backend closure must attempt only this URL, refuse redirects and report pre-upgrade
  /// rejection as handshakeRejected with the actual response when available. It must respond to
  /// cancellation by aborting its pending attempt. A late successful connection is passed to
  /// discard, so even a cancellation-insensitive backend cannot return an unowned connection.
  /// This package entry point does not publish a live connection or backend protocol.
  package static func connect<C: Clock, Connection: Sendable>(
    _ request: WebSocketRequest,
    clock: C,
    discard: @escaping @Sendable (Connection) -> Void,
    timeout: Duration = .seconds(30),
    through handshake:
      @escaping @Sendable (WebSocketRequest) async throws(WebSocketError) -> Connection
  ) async throws(WebSocketError) -> Connection where C.Duration == Duration {
    let deadline = clock.now.advanced(by: timeout)
    guard !Task.isCancelled else { throw WebSocketError(kind: .cancelled) }
    guard timeout > .zero else { throw WebSocketError(kind: .invalidRequest) }
    try request.validate()
    let wait = WebSocketConnectWait(discard: discard)
    return try await wait.run(clock: clock, deadline: deadline) { () throws(WebSocketError) in
      @Sendable func check() throws(WebSocketError) {
        try wait.check()
        guard clock.now < deadline else { throw WebSocketError(kind: .timedOut) }
      }

      try check()
      if let authentication = request.authentication {
        do throws(TransportError) {
          try await authentication.refreshIfExpiring()
        } catch {
          try check()
          throw credentialFailure(error)
        }
      }
      try check()
      let observed = request.authentication?.provider.currentToken()
      try check()
      let first = try authorized(request, token: observed)
      let connection: Connection
      do throws(WebSocketError) {
        connection = try await handshake(first)
      } catch {
        try check()
        guard error.kind == .handshakeRejected, error.response?.status == .unauthorized,
          let authentication = request.authentication,
          authentication.replayOn401, authentication.refresher != nil
        else { throw error }
        do throws(TransportError) {
          try await authentication.refresh(replacing: observed)
        } catch {
          try check()
          throw credentialFailure(error)
        }
        try check()
        let token = authentication.provider.currentToken()
        try check()
        connection = try await handshake(authorized(request, token: token))
      }
      do throws(WebSocketError) {
        try check()
      } catch {
        discard(connection)
        throw error
      }
      return connection
    }
  }

  private static func authorized(_ request: WebSocketRequest, token: String?)
    throws(WebSocketError) -> WebSocketRequest
  {
    var result = request
    result.authentication = nil
    if let authentication = request.authentication {
      let value = token.map { authentication.scheme.value(for: $0) }
      if let value, !HTTPField.isValidValue(value) {
        throw WebSocketError(kind: .invalidRequest)
      }
      // The authentication source owns its field even when it has no token.
      result.headers[authentication.scheme.fieldName] = value
    }
    return result
  }

  private static func credentialFailure(_ error: TransportError) -> WebSocketError {
    if case .cancelled = error { return WebSocketError(kind: .cancelled, underlying: error) }
    return WebSocketError(kind: .transport, underlying: error)
  }
}
