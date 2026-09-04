/// A transport-neutral hint for how a request may use a local response cache.
///
/// The hint names an intent, and each transport maps it onto whatever cache it owns. A transport
/// with no cache, or with no distinct behaviour for a given case, treats that case as ``standard``,
/// so the same request value stays valid across transports. For a guarantee instead of a hint, send
/// explicit `Cache-Control` header fields.
///
/// ```swift
/// let request = Request(
///   options: RequestOptions(cachePolicy: .ignoreCache),
///   path: "/prices"
/// )
/// ```
public enum CachePolicy: Hashable, Sendable {
  /// Serve a cached response regardless of its age, going to the server only when nothing is
  /// cached.
  case cacheElseLoad

  /// Serve a cached response regardless of its age and never go to the server, failing when nothing
  /// is cached.
  case cacheOnly

  /// Skip any cached response and load from the server.
  case ignoreCache

  /// Revalidate a cached response with the server before serving it, however fresh it looks.
  case revalidate

  /// Follow the protocol's own freshness rules: `Cache-Control`, `Expires`, and validators.
  case standard
}
