/// A failure ``RecordingTokenProvider`` produced itself, which no live credential source reports.
///
/// The failure arrives as the underlying error of
/// ``/HTTPCore/TransportError/transport(kind:underlying:)`` with the kind
/// ``/HTTPCore/TransportFailureKind/other``. Read it back to tell a seeding mistake from a failure
/// the test scripted on purpose:
///
/// ```swift
/// #expect(error.underlying as? RecordingTokenProviderFailure == .noSeededOutcome)
/// ```
public enum RecordingTokenProviderFailure: Error, Hashable, Sendable {
  /// A refresh was asked for after every seeded outcome had been taken.
  case noSeededOutcome
}
