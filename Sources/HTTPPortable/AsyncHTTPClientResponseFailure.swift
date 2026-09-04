// The failure names an answer the AsyncHTTPClient transport could not read, so it compiles only
// where the transport does, behind the `HTTPPortable` trait.
#if HTTPPortable

/// An answer AsyncHTTPClient delivered that ``AsyncHTTPClientTransport`` could not read as HTTP.
///
/// Building a ``/HTTPCore/Response`` takes header fields whose names this package can represent
/// and a status in the range an HTTP status can take. AsyncHTTPClient's HTTP/1 parser accepts the
/// same names and no status past three digits, so a response that arrives over HTTP/1 never trips
/// this, but an HTTP/2 `:status` is converted as any integer and the conversion is checked rather
/// than assumed: a name or a status this package cannot take fails the whole response instead of
/// dropping the field or trapping.
///
/// This is not a network failure, so this is the error ``AsyncHTTPClientTransport`` supplies in
/// place of one. It travels as the underlying error of a
/// ``/HTTPCore/TransportError/transport(kind:underlying:)`` whose kind is
/// ``/HTTPCore/TransportFailureKind/other``.
///
/// ```swift
/// do {
///   let response = try await transport.send(
///     request, body: .none, options: TransportOptions())
///   handle(response)
/// } catch {
///   if let failure = error.underlying as? AsyncHTTPClientResponseFailure {
///     log("\(failure)")
///   }
/// }
/// ```
public enum AsyncHTTPClientResponseFailure: Error {
  /// A response header field's name is not one an HTTP field can carry, so no field was built for
  /// it.
  ///
  /// - Parameter name: The name exactly as the client delivered it.
  case invalidHeaderFieldName(name: String)

  /// The response's status is not one an HTTP response represents, so no response was built for
  /// it.
  ///
  /// - Parameter code: The status exactly as the client delivered it, outside the range a status
  ///   can take.
  case unrepresentableStatus(code: Int)
}

extension AsyncHTTPClientResponseFailure: CustomStringConvertible {
  /// A one-line summary that is safe to log: what arrived, and the field name or status that could
  /// not be represented.
  public var description: String {
    switch self {
    case .invalidHeaderFieldName(let name):
      "AsyncHTTPClient answered with a header field named \(name), which no HTTP field can carry"
    case .unrepresentableStatus(let code):
      "AsyncHTTPClient answered with HTTP status \(code), which no HTTP response represents"
    }
  }
}

#endif
