/// The per-request settings a transport honours, projected from ``RequestOptions``.
///
/// ``HTTPClient`` builds one for every call it makes on a ``Transport``, carrying the settings the
/// transport itself acts on and nothing the client has already applied. Every property has a
/// default, so a transport written against one property keeps compiling when another is added, and
/// a caller building one by hand names only what differs.
///
/// ```swift
/// let options = TransportOptions(cachePolicy: .ignoreCache)
/// let response = try await transport.send(request, body: .none, options: options)
/// ```
public struct TransportOptions: Hashable, Sendable {
  /// How the request may use the transport's response cache; `nil` leaves the transport's own
  /// default in place.
  ///
  /// A transport maps each ``CachePolicy`` case onto whatever cache it owns, and a transport with
  /// no cache treats every case as ``CachePolicy/standard``. `URLSessionTransport` sets the
  /// matching `URLRequest.CachePolicy` on the request it sends.
  public var cachePolicy: CachePolicy?

  /// Creates transport options.
  ///
  /// - Parameter cachePolicy: The cache hint; defaults to `nil`, the transport's own default.
  public init(cachePolicy: CachePolicy? = nil) {
    self.cachePolicy = cachePolicy
  }
}
