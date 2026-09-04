/// The class of failure a transport hit before any response arrived.
///
/// The kinds let a retry or connectivity policy tell a timeout from a dead network from an
/// unsendable URL without downcasting a transport's own error type. They are coarse: they are the
/// distinctions a policy acts on, not a catalogue of every way a connection can fail. A transport
/// maps a failure it cannot place onto ``other`` and keeps the original error alongside it, in
/// ``TransportError/transport(kind:underlying:)``.
///
/// ```swift
/// if case .transport(let kind, _) = error, kind == .connectivity {
///   showOfflineBanner()
/// }
/// ```
public enum TransportFailureKind: Hashable, Sendable {
  /// The request could not be turned into a URL the transport is able to send.
  case badURL

  /// The network was unavailable, or the connection could not be established or was lost.
  case connectivity

  /// A failure the transport could not classify as one of the other kinds.
  case other

  /// The request's deadline passed before a complete response arrived.
  case timedOut
}
