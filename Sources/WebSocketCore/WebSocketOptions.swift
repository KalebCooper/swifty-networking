extension WebSocket {
  /// Message limits and send configuration shared by client and accepted server connections.
  ///
  /// Values are captured when opening a connection and validated before backend work.
  /// Receive capacities bound completed application messages, excluding backend buffers.
  public struct Options: Equatable, Sendable {
    /// The bounded close-attempt budget; defaults to five seconds.
    public var closeTimeout: Duration

    /// One budget for credentials and connection attempts; defaults to thirty seconds.
    public var connectTimeout: Duration

    /// The payload-byte capacity of the completed-message inbox.
    ///
    /// The default is 1 MiB. A live connection requires a positive capacity at least
    /// as large as maxMessageBytes. Text counts its UTF-8 bytes.
    public var maxBufferedBytes: Int

    /// The completed-message capacity of the inbox, including empty messages.
    ///
    /// The default is 16. A live connection requires a positive capacity.
    public var maxBufferedMessages: Int

    /// The maximum payload size of one message in bytes.
    ///
    /// The default is 1 MiB. A live connection requires a positive limit.
    /// Text counts its UTF-8 bytes.
    public var maxMessageBytes: Int

    /// The payload-byte capacity for active and queued sends together.
    ///
    /// The default is 1 MiB. A live connection requires a positive capacity.
    public var maxPendingSendBytes: Int

    /// The message capacity for active and queued sends together, including empty messages.
    ///
    /// The default is 16. A live connection requires a positive capacity.
    public var maxPendingSendMessages: Int

    /// The pong deadline, retained after caller cancellation; defaults to ten seconds.
    public var pingTimeout: Duration

    /// The connection's default response to a local send failure.
    public var sendFailurePolicy: SendFailurePolicy

    /// The connection's default admission policy for overlapping sends.
    public var sendPolicy: SendPolicy

    /// Creates message and send configuration with caller-adjustable capacities.
    public init(
      closeTimeout: Duration = .seconds(5),
      connectTimeout: Duration = .seconds(30),
      maxBufferedBytes: Int = 1_048_576,
      maxBufferedMessages: Int = 16,
      maxMessageBytes: Int = 1_048_576,
      maxPendingSendBytes: Int = 1_048_576,
      maxPendingSendMessages: Int = 16,
      pingTimeout: Duration = .seconds(10),
      sendFailurePolicy: SendFailurePolicy = .preserveIfUnsent,
      sendPolicy: SendPolicy = .serialize
    ) {
      self.closeTimeout = closeTimeout
      self.connectTimeout = connectTimeout
      self.maxBufferedBytes = maxBufferedBytes
      self.maxBufferedMessages = maxBufferedMessages
      self.maxMessageBytes = maxMessageBytes
      self.maxPendingSendBytes = maxPendingSendBytes
      self.maxPendingSendMessages = maxPendingSendMessages
      self.pingTimeout = pingTimeout
      self.sendFailurePolicy = sendFailurePolicy
      self.sendPolicy = sendPolicy
    }

    func validate() throws(WebSocketError) {
      guard closeTimeout > .zero, connectTimeout > .zero, pingTimeout > .zero,
        maxBufferedBytes >= maxMessageBytes, maxBufferedMessages > 0, maxMessageBytes > 0,
        maxPendingSendBytes >= maxMessageBytes, maxPendingSendMessages > 0
      else { throw WebSocketError(kind: .invalidRequest) }
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
