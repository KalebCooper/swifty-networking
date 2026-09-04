// A `URLError` exists only where URLSession's loading system does, so this failure compiles only on
// the platforms the rest of the target does.
#if canImport(Darwin)

import Foundation

/// The error a `URLSession` reported, carried in a form that is safe to log.
///
/// A `URLError` describes itself with its whole `userInfo`, the failing URL included, and that URL
/// is routinely signed, carrying a credential in its query.
/// ``/HTTPCore/TransportError/description`` includes the description of the error it wraps and
/// guarantees a line that can go into a log unread, so ``URLSessionTransport`` wraps every
/// `URLError` in this type. Its ``description`` names the code and reduces the failing URL to
/// scheme, host, and path, dropping the query, the fragment, and any user or password in the
/// authority.
///
/// Nothing is lost: ``urlError`` is the error exactly as `URLSession` reported it, for when you
/// want the domain, the `userInfo`, or the failing URL in full. Read it from here, because
/// ``/HTTPCore/TransportError/underlying`` holds this wrapper and not the `URLError`.
///
/// ```swift
/// do {
///   let response = try await transport.send(
///     request, body: .none, options: TransportOptions())
///   handle(response)
/// } catch {
///   guard let failure = error.underlying as? URLSessionTransportFailure else { throw error }
///   log("\(failure)")  // redacted, safe to log
///   if failure.code == .timedOut { scheduleRetry() }
/// }
/// ```
public struct URLSessionTransportFailure: Error {
  /// The code `URLSession` failed the request with.
  ///
  /// The value is read from ``urlError``, and always matches it.
  public var code: URLError.Code { urlError.code }

  /// The error exactly as `URLSession` reported it, with nothing removed.
  ///
  /// Its own description carries the failing URL in full. Read its code or its fields, and print
  /// the wrapper when the line goes into a log.
  public let urlError: URLError

  /// Wraps the error a `URLSession` task failed with.
  ///
  /// - Parameter urlError: The error as `URLSession` reported it.
  public init(_ urlError: URLError) {
    self.urlError = urlError
  }
}

extension URLSessionTransportFailure: CustomStringConvertible {
  /// A one-line summary that is safe to log: the code, and the failing URL with every component a
  /// credential can hide in removed.
  ///
  /// A failure that names no URL, or names one that cannot be parsed, is described by its code
  /// alone.
  public var description: String {
    guard let redacted = urlError.failingURL?.redacted else {
      return "URLSession error \(code.rawValue)"
    }
    return "URLSession error \(code.rawValue) for \(redacted)"
  }
}

#endif
