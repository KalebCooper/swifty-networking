extension WebSocket {
  /// A WebSocket close code, including application-defined values.
  ///
  /// Construction preserves the raw value. It does not validate whether a code may be sent.
  public struct CloseCode: Hashable, RawRepresentable, Sendable {
    /// The peer is leaving or shutting down.
    public static let goingAway = Self(rawValue: 1001)

    /// The connection completed normally.
    public static let normalClosure = Self(rawValue: 1000)

    /// The unmodified wire value.
    public let rawValue: UInt16

    /// Creates a code without restricting application-defined values.
    public init(rawValue: UInt16) {
      self.rawValue = rawValue
    }
  }
}
