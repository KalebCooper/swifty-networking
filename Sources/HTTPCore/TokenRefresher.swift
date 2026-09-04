/// A type that obtains a fresh credential when the current one has expired or is about to.
///
/// A refresher returns nothing. It installs the new credential into whatever store its paired
/// ``TokenProvider`` reads, and the client then re-reads ``TokenProvider/currentToken()`` to build
/// the next attempt. The provider stays the single source of truth, so there is never a returned
/// token and an installed token that could disagree.
///
/// ```swift
/// struct SessionRefresher: TokenRefresher {
///   let store: TokenStore
///
///   func refresh() async throws(TransportError) {
///     store.install(try await fetchNewToken())
///   }
/// }
/// ```
///
/// ## Conforming to the Protocol
///
/// - After ``refresh()`` returns, the paired provider's ``TokenProvider/currentToken()`` yields the
///   new credential.
/// - When ``refresh()`` throws, the provider's previous token is left exactly as it was. The client
///   decides whether to replay by looking at what the provider then holds.
/// - The client never runs two refreshes at once. Concurrent requests that all hit a `401` share
///   one in-flight refresh and each replay once it completes, so write ``refresh()`` as a plain
///   sequential operation.
/// - Throw when the credential is gone for good, such as a revoked session or a rejected refresh
///   token, instead of installing a token you know will fail. The client then surfaces the original
///   `401` instead of looping.
///
/// A client configured without a refresher attaches whatever the provider holds and treats a `401`
/// like any other status failure, which is the whole configuration for an app whose credentials are
/// managed outside the request path.
public protocol TokenRefresher: Sendable {
  /// Obtains a new credential and installs it where the paired ``TokenProvider`` will read it.
  ///
  /// - Throws: A ``TransportError`` when no new credential could be obtained; the provider's
  ///   previous token is untouched.
  func refresh() async throws(TransportError)
}
