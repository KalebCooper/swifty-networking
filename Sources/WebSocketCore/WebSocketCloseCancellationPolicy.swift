extension WebSocket {
  /// The effect of cancelling a caller after it starts or joins a graceful close.
  public enum CloseCancellationPolicy: Equatable, Sendable {
    /// Abort the connection, ending the shared close for every waiter.
    case abortConnection

    /// Stop only this caller's wait, leaving the shared close and its deadline running.
    case stopWaiting
  }
}
