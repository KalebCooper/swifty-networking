/// What two keyed requests must agree on before they share one exchange: the caller's key, and the
/// credential the request would be sent under.
///
/// The key is the exact string the caller supplied and carries nothing about credentials, so on its
/// own it would let a request join an exchange sent under someone else's token and be handed that
/// response. The credential half is the ``Authentication`` value's identity when the request requires
/// auth, and `nil` when it is sent anonymously, so an anonymous request and an authenticated one,
/// or two requests under different credentials, never share a flight however alike their keys.
struct CoalescingIdentity: Hashable, Sendable {
  /// The identity of the ``Authentication`` the request is sent under; `nil` for a request sent
  /// without one.
  var credential: ObjectIdentifier?

  /// The ``RequestOptions/coalescingKey`` the caller supplied, unchanged.
  var key: String
}
