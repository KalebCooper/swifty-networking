/// Per-request policy settings a client honours while executing a request.
///
/// Every property has a default, so `RequestOptions()` describes the common case and you name only
/// what differs. Nothing here is transport-specific: a transport receives the resolved effect of
/// these settings, never the options themselves.
///
/// ```swift
/// let request = Request(
///   options: RequestOptions(
///     coalescingKey: "profile", redirectPolicy: .sameOrigin, requiresAuth: true,
///     timeout: .seconds(5)),
///   path: "/me"
/// )
/// ```
public struct RequestOptions: Sendable {
  /// How the request may use a local response cache; `nil` leaves the transport's own default in
  /// place.
  ///
  /// ``HTTPClient`` hands the value to the transport as ``TransportOptions/cachePolicy``, and the
  /// transport maps it onto whatever cache it owns. With `URLSessionTransport`, each case sets the
  /// matching `URLRequest.CachePolicy` on the request it sends, and `nil` leaves the session
  /// configuration's `requestCachePolicy` in charge.
  public var cachePolicy: CachePolicy?

  /// The key under which concurrent identical requests share a single in-flight execution.
  ///
  /// The default, `nil`, never coalesces. Set it on idempotent reads only: every caller sharing a
  /// key receives the same response, so a write coalesced this way is sent once and answered many
  /// times.
  ///
  /// The key is an exact string, scoped to the client and its copies; the client never derives one.
  /// When two requests that differ share a key, the first to arrive is the one sent and its
  /// response is what every caller receives. A caller cancelled while it waits throws
  /// ``TransportError/cancelled``, and the shared exchange finishes for the rest.
  public var coalescingKey: String?

  /// What this request does with a `3xx` that names a `Location`; `nil`, the default, uses the
  /// client's ``HTTPClient/redirectPolicy``.
  ///
  /// Set it where one endpoint differs from the rest: a download whose `302` to a storage host is
  /// the answer you want, or a form post that must never be replayed elsewhere. A redirect the
  /// policy does not follow is returned as the response it was, and every entry point throws it as
  /// ``TransportError/httpStatus(body:code:headers:)`` with the `Location` field in `headers`.
  public var redirectPolicy: RedirectPolicy?

  /// A Boolean value that indicates whether the client attaches credentials before sending.
  ///
  /// Set it to `false` for anonymous endpoints such as sign-in, where a stale token must not be
  /// replayed.
  public var requiresAuth: Bool

  /// A retry policy for this request alone; `nil`, the default, uses the client's own.
  ///
  /// Set it where one endpoint's retry behaviour differs from the rest: a long poll that should
  /// never be replayed, or an idempotent read that can afford more attempts than the client's
  /// default.
  public var retryPolicy: RetryPolicy?

  /// A deadline for this request alone, measured on the client's clock; `nil`, the default, uses
  /// the client's ``HTTPClient/timeout``.
  ///
  /// The deadline bounds the whole request, every attempt and the waits between them, and a request
  /// that reaches it throws ``TransportError/transport(kind:underlying:)`` with
  /// ``TransportFailureKind/timedOut``. Set it where one endpoint's patience differs from the rest:
  /// a search that must answer quickly or not at all, or a report that takes longer than the
  /// client's default allows. A deadline of zero or less has already passed, so the request fails
  /// at once. ``HTTPClient/stream(_:)`` ignores it.
  public var timeout: Duration?

  /// Creates request options.
  ///
  /// - Parameters:
  ///   - cachePolicy: The cache hint; defaults to `nil`, the transport's default.
  ///   - coalescingKey: The coalescing key; defaults to `nil`, which never coalesces.
  ///   - redirectPolicy: The per-request redirect policy; defaults to `nil`, the client's own.
  ///   - requiresAuth: Whether credentials are attached; defaults to `true`.
  ///   - retryPolicy: The per-request retry policy; defaults to `nil`, the client's own.
  ///   - timeout: The per-request deadline; defaults to `nil`, the client's own.
  public init(
    cachePolicy: CachePolicy? = nil, coalescingKey: String? = nil,
    redirectPolicy: RedirectPolicy? = nil, requiresAuth: Bool = true,
    retryPolicy: RetryPolicy? = nil, timeout: Duration? = nil
  ) {
    self.cachePolicy = cachePolicy
    self.coalescingKey = coalescingKey
    self.redirectPolicy = redirectPolicy
    self.requiresAuth = requiresAuth
    self.retryPolicy = retryPolicy
    self.timeout = timeout
  }
}
