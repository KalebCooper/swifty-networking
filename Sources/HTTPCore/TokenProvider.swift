/// A type that supplies the credential a client attaches to an authenticated request.
///
/// The client reads the credential at send time on every attempt, so the read is synchronous: keep
/// the current token in memory behind a `Mutex` and return it without suspending. Where the token
/// comes from is not this protocol's concern. A ``TokenRefresher`` writes, a provider reads, and
/// the two meet in whatever store you own.
///
/// ```swift
/// import HTTPCore
/// import Synchronization
///
/// final class TokenStore: TokenProvider, Sendable {
///   private let token = Mutex<String?>(nil)
///
///   func currentToken() -> String? { token.withLock { $0 } }
///   func install(_ newToken: String) { token.withLock { $0 = newToken } }
/// }
/// ```
///
/// A provider goes into a client as the ``Authentication/provider`` of an ``Authentication``. On
/// its own it gives the client attach-on-send and nothing more. Proactive refresh also needs
/// ``timeUntilExpiry`` to report a value and an ``Authentication/refreshThreshold`` to compare it
/// against, and both refresh paths need an ``Authentication/refresher``. Without those, a provider
/// that returns `nil` sends the request unauthenticated.
public protocol TokenProvider: Sendable {
  /// Returns the credential to attach right now, or `nil` when there is none.
  ///
  /// Return the credential with no scheme prefix; the client renders it into a header field under
  /// ``Authentication/scheme``. Under ``Authentication/Scheme/basic`` the credential is the base64
  /// RFC 7617 defines, so encode the user name and password where you store them. A `nil` return
  /// means "send without credentials", not "wait": never block here.
  ///
  /// - Returns: The current credential, or `nil`.
  func currentToken() -> String?

  /// How long the current credential remains valid, or `nil` when the provider does not know.
  ///
  /// The value is a remaining lifetime, not an absolute instant, so no clock type crosses the
  /// boundary: you own whatever clock computes it, and the client compares it directly against
  /// ``Authentication/refreshThreshold``. A zero or negative value means the credential has already
  /// expired. The default is `nil`, which opts a provider out of proactive refresh entirely,
  /// leaving the client to learn of expiry from the server's `401`.
  var timeUntilExpiry: Duration? { get }
}

extension TokenProvider {
  /// Reports an unknown expiry, so a provider that does not track one never triggers a proactive
  /// refresh.
  public var timeUntilExpiry: Duration? { nil }
}
