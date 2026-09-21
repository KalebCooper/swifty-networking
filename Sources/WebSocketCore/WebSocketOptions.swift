extension WebSocket {
  /// Send configuration shared by client and accepted server connections.
  ///
  /// These values describe admission policy; they do not implement a send queue.
  /// Live connections and validation are not available yet. Receive limits and deadlines
  /// are not configured by this type.
  public struct Options: Equatable, Sendable {
    /// The payload-byte capacity for active and queued sends together.
    ///
    /// The default is 1 MiB. A live connection requires a positive capacity.
    public var maxPendingSendBytes: Int

    /// The message capacity for active and queued sends together, including empty messages.
    ///
    /// The default is 16. A live connection requires a positive capacity.
    public var maxPendingSendMessages: Int

    /// The connection's default response to a local send failure.
    public var sendFailurePolicy: SendFailurePolicy

    /// The connection's default admission policy for overlapping sends.
    public var sendPolicy: SendPolicy

    /// Creates send configuration with caller-adjustable capacities.
    public init(
      maxPendingSendBytes: Int = 1_048_576,
      maxPendingSendMessages: Int = 16,
      sendFailurePolicy: SendFailurePolicy = .preserveIfUnsent,
      sendPolicy: SendPolicy = .serialize
    ) {
      self.maxPendingSendBytes = maxPendingSendBytes
      self.maxPendingSendMessages = maxPendingSendMessages
      self.sendFailurePolicy = sendFailurePolicy
      self.sendPolicy = sendPolicy
    }
  }

  /// The response to a send failure before a backend write begins.
  public enum SendFailurePolicy: Equatable, Sendable {
    /// Abort the connection so later dependent messages cannot begin writing.
    case abortConnection

    /// Fail only the operation when its backend write has not started.
    ///
    /// Failure after writing begins requires aborting the connection under either policy.
    case preserveIfUnsent
  }

  /// Admission behavior when another send is active or queued.
  public enum SendPolicy: Equatable, Sendable {
    /// Reject the new send when another send is outstanding.
    case rejectOverlapping

    /// Admit sends in order within the configured byte and message capacities.
    case serialize
  }
}
