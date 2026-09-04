// The failure names response types the loading system produces, which exist only on Apple
// platforms, so it compiles only where the rest of the target does.
#if canImport(Darwin)

import Foundation

/// An answer `URLSession` reported as a success that ``URLSessionTransport`` could not read as
/// HTTP.
///
/// Building a ``/HTTPCore/Response`` takes a status and header fields. Two answers carry neither,
/// and `URLSession` delivers both as successes with no error of its own: a response that is not an
/// `HTTPURLResponse`, which is how a `file:` or `data:` URL is answered and how a custom
/// `URLProtocol` may answer anything, and an `HTTPURLResponse` whose status falls outside the range
/// HTTP statuses represent, which `HTTPURLResponse` stores and returns unchanged.
///
/// Neither is a network failure, so this is the error ``URLSessionTransport`` supplies in place of
/// one. It travels as the underlying error of a
/// ``/HTTPCore/TransportError/transport(kind:underlying:)`` whose kind is
/// ``/HTTPCore/TransportFailureKind/other``.
///
/// ```swift
/// do {
///   let response = try await transport.send(
///     request, body: .none, options: TransportOptions())
///   handle(response)
/// } catch {
///   if let failure = error.underlying as? URLSessionResponseFailure {
///     log("\(failure)")  // redacted, safe to log
///   }
/// }
/// ```
///
/// Like ``URLSessionTransportFailure``, this failure keeps what arrived in full and redacts only
/// when describing itself: the URL is stored whole, and ``description`` reduces it to scheme, host,
/// and path.
public enum URLSessionResponseFailure: Error {
  /// The response was not an `HTTPURLResponse`, so it carried no status or header fields to report.
  ///
  /// - Parameters:
  ///   - responseType: The name of the type that arrived, which says how the request was answered:
  ///     a plain `URLResponse` for a `file:` or `data:` URL, or whatever a custom `URLProtocol`
  ///     returned.
  ///   - url: The URL the response named, when it named one.
  case notHTTP(responseType: String, url: URL?)

  /// The response was an `HTTPURLResponse`, but its status is not one an HTTP response represents.
  ///
  /// - Parameters:
  ///   - code: The status exactly as the response carried it, outside the range a status can take.
  ///   - url: The URL the response named, when it named one.
  case unrepresentableStatus(code: Int, url: URL?)
}

extension URLSessionResponseFailure: CustomStringConvertible {
  /// A one-line summary that is safe to log: what arrived, and the URL with every component a
  /// credential can hide in removed.
  ///
  /// A response that names no URL, or names one that cannot be parsed, is described by what arrived
  /// alone.
  public var description: String {
    switch self {
    case .notHTTP(let responseType, let url):
      Self.line("URLSession answered with \(responseType), which is not an HTTP response", for: url)
    case .unrepresentableStatus(let code, let url):
      Self.line(
        "URLSession answered with HTTP status \(code), which no HTTP response represents", for: url)
    }
  }

  /// The summary, followed by the endpoint it happened at when there is one to name.
  private static func line(_ summary: String, for url: URL?) -> String {
    guard let redacted = url?.redacted else { return summary }
    return "\(summary) for \(redacted)"
  }
}

#endif
