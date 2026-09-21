extension WebSocket {
  /// The shared completion of one synchronously admitted send.
  ///
  /// Admission is not delivery. Multiple callers may wait for the same cached result.
  /// Cancelling a waiter stops only that wait. Use cancel() to cancel the send itself.
  /// Dropping this value does not cancel its send or keep an otherwise released socket alive.
  public struct SendOperation: Sendable {
    private let cancellation: @Sendable () -> Void
    private let completion: WebSocketCompletion<Void>

    init(cancellation: @escaping @Sendable () -> Void, completion: WebSocketCompletion<Void>) {
      self.cancellation = cancellation
      self.completion = completion
    }

    /// Cancels the send idempotently under its captured failure policy.
    ///
    /// An unstarted send can be removed without affecting the connection under preserveIfUnsent.
    /// Cancellation after writing starts aborts the connection. A completed send cannot be undone.
    public func cancel() { cancellation() }

    /// Waits for backend write completion without claiming remote application delivery.
    ///
    /// Cancelling this caller throws cancelled without changing the operation or other waiters.
    /// Completed results can be read again. Failed writes may have reached the peer.
    /// Observer storage grows with active waiters and is released on cancellation or completion.
    public func wait() async throws(WebSocketError) { try await completion.wait() }
  }
}
