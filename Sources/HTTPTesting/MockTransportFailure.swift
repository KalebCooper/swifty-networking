/// A failure ``MockTransport`` produced itself, which no live transport reports.
///
/// The failure arrives as the underlying error of
/// ``/HTTPCore/TransportError/transport(kind:underlying:)`` with the kind
/// ``/HTTPCore/TransportFailureKind/other``. Read it back to tell a seeding mistake from a failure
/// the test scripted on purpose:
///
/// ```swift
/// #expect(error.underlying as? MockTransportFailure == .noCannedResponse)
/// ```
public enum MockTransportFailure: Error, Hashable, Sendable {
  /// A request arrived with no handler registered for its path and nothing left in the queue it
  /// falls to, whether it was sent or streamed.
  case noCannedResponse
}
