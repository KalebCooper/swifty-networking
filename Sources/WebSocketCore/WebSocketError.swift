import HTTPTypes

/// A WebSocket failure with optional diagnostics.
///
/// The description excludes request data, peer reasons and underlying error descriptions.
/// Raw diagnostics, including custom kind values, are not guaranteed safe to log.
public struct WebSocketError: CustomStringConvertible, Error, Sendable {
  /// An extensible classification of WebSocket failures.
  public struct Kind: Hashable, RawRepresentable, Sendable {
    /// A receive buffer could not admit a message.
    public static let bufferOverflow = Self(rawValue: "bufferOverflow")
    /// An operation was cancelled.
    public static let cancelled = Self(rawValue: "cancelled")
    /// The connection is closed.
    public static let closed = Self(rawValue: "closed")
    /// An operation conflicted with another operation.
    public static let concurrentOperation = Self(rawValue: "concurrentOperation")
    /// The server rejected an opening handshake.
    public static let handshakeRejected = Self(rawValue: "handshakeRejected")
    /// Request inputs are invalid.
    public static let invalidRequest = Self(rawValue: "invalidRequest")
    /// A message exceeds its configured size limit.
    public static let messageTooLarge = Self(rawValue: "messageTooLarge")
    /// The peer violated the WebSocket protocol.
    public static let protocolViolation = Self(rawValue: "protocolViolation")
    /// The configured send capacity cannot admit another message.
    public static let sendQueueFull = Self(rawValue: "sendQueueFull")
    /// An operation exceeded its deadline.
    public static let timedOut = Self(rawValue: "timedOut")
    /// The underlying transport failed.
    public static let transport = Self(rawValue: "transport")

    /// The classification's unmodified value.
    public let rawValue: String

    /// Creates a known or custom classification.
    public init(rawValue: String) {
      self.rawValue = rawValue
    }
  }

  /// Close metadata, when available.
  public let close: WebSocketClose?

  /// The failure classification.
  public let kind: Kind

  /// The actual handshake response, when available.
  public let response: HTTPResponse?

  /// The original error, when available.
  public let underlying: (any Error)?

  /// Creates a failure without synthesizing missing diagnostics.
  public init(
    close: WebSocketClose? = nil,
    kind: Kind,
    response: HTTPResponse? = nil,
    underlying: (any Error)? = nil
  ) {
    self.close = close
    self.kind = kind
    self.response = response
    self.underlying = underlying
  }

  /// A diagnostic summary that excludes arbitrary raw values and sensitive metadata.
  public var description: String {
    let known: [Kind] = [
      .bufferOverflow, .cancelled, .closed, .concurrentOperation, .handshakeRejected,
      .invalidRequest, .messageTooLarge, .protocolViolation, .sendQueueFull, .timedOut, .transport,
    ]
    let label = known.contains(kind) ? kind.rawValue : "custom"
    return "WebSocket failure: \(label)"
  }
}
