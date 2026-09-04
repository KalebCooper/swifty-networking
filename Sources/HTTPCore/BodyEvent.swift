/// How a streamed body ended, reported once when the consumer's read reaches the end or a failure.
///
/// A streamed response is reported as a ``ResponseEvent`` when its status and header fields
/// arrive, before any of its body has. This event is the rest of the record: it is reported from
/// the consumer's own read, inline in the read that returned `nil` or threw, so it arrives once
/// per body and only after every chunk delivered before the end. A body dropped before it ended
/// reports nothing, because the release can happen inside a buffer's critical section, where no
/// observer may run. A consumer cancelled part-way through reports ``TransportError/cancelled``
/// as its ``failure``, the same value its read threw.
///
/// The event carries no header fields, no credential, and no bytes: ``bytesReceived`` is a count,
/// never content, so nothing here needs redacting before it is logged.
///
/// ```swift
/// struct BodyLogger: TransportObserver {
///   func didFinishBody(_ event: BodyEvent) {
///     if let failure = event.failure {
///       print("\(event.correlationID) failed after \(event.bytesReceived) bytes: \(failure)")
///     } else {
///       print("\(event.correlationID) delivered \(event.bytesReceived) bytes")
///     }
///   }
/// }
/// ```
public struct BodyEvent: Sendable {
  /// How many bytes the consumer's reads returned before the body ended.
  ///
  /// The count is of chunks handed to the consumer, so bytes a transport buffered and never
  /// delivered are not in it.
  public var bytesReceived: Int

  /// The identifier shared by every event belonging to one logical request, retries included.
  ///
  /// The value is opaque to the package: it is carried and never parsed.
  public var correlationID: String

  /// The failure that ended the body, or `nil` when it ended cleanly.
  ///
  /// ``TransportError/description`` is safe to record. The failure's payload is whatever the
  /// transport threw, and may say more than an observer wants to keep.
  public var failure: TransportError?

  /// Creates a body event.
  ///
  /// - Parameters:
  ///   - bytesReceived: How many bytes the consumer received.
  ///   - correlationID: The identifier shared across the logical request's events.
  ///   - failure: The failure that ended the body; defaults to `nil`, a clean end.
  public init(bytesReceived: Int, correlationID: String, failure: TransportError? = nil) {
    self.bytesReceived = bytesReceived
    self.correlationID = correlationID
    self.failure = failure
  }
}
