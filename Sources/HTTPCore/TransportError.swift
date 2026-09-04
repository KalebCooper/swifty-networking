// `Data` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTypes

/// The one error every transport and client operation in this package throws.
///
/// The error is thrown as a typed error, so a `catch` clause binds it as a `TransportError`, a
/// `switch` over it is exhaustive without a `default`, and the compiler checks both. The cases
/// split by who failed, which is what decides your next move: give up, fix the payload, read the
/// status, or retry.
///
/// ```swift
/// do {
///   let profile: Profile = try await client.execute(Request(path: "/me"))
///   show(profile)
/// } catch {
///   switch error {
///   case .cancelled: break
///   case .decode(let underlying): report("Unexpected shape: \(underlying)")
///   case .encode(let underlying): report("Nothing was sent: \(underlying)")
///   case .httpStatus(_, let code, _): report("The server refused with \(code).")
///   case .transport(let kind, _): report("No response arrived: \(kind).")
///   }
/// }
/// ```
///
/// ``isTimeout``, ``statusCode``, and ``underlying`` answer the common questions without a
/// `switch`.
///
/// A payload that wraps another error holds it as `any Error`. `Error` already refines `Sendable`,
/// so the type crosses isolation boundaries with no further constraint on what a transport or coder
/// throws.
public enum TransportError: Error {
  /// The task running the request was cancelled before a response arrived.
  case cancelled

  /// A response arrived but its body could not be decoded into the requested type.
  ///
  /// - Parameter underlying: The coder's own error.
  case decode(underlying: any Error)

  /// The request body could not be encoded, so nothing was sent.
  ///
  /// - Parameter underlying: The coder's own error.
  case encode(underlying: any Error)

  /// The server answered with a status the client does not treat as success.
  ///
  /// The body and header fields travel with the failure, so you can read an error envelope or a
  /// `Retry-After` field without a second request. ``HTTPClient/stream(_:)`` carries at most the
  /// first 64 KiB of the body, because the failure arrives with the body still on its way and the
  /// client stops reading it there.
  ///
  /// - Parameters:
  ///   - body: The response body as received, truncated at 64 KiB for a streamed response; empty
  ///     when the server sent none.
  ///   - code: The HTTP status code.
  ///   - headers: The response header fields.
  case httpStatus(body: Data, code: Int, headers: HTTPFields)

  /// The request never produced a response: it could not be sent, or the connection failed or timed
  /// out before one arrived.
  ///
  /// The underlying error is optional because not every transport failure has a system error behind
  /// it. A ``TransportFailureKind/badURL`` comes from the client's own base-URL and path join, and
  /// the client's own ``HTTPClient/timeout``, like a mock transport, reports a
  /// ``TransportFailureKind/timedOut`` with no system error to attach.
  ///
  /// - Parameters:
  ///   - kind: The class of failure, for policies that must not depend on a transport's error type.
  ///   - underlying: The transport's own error, when there is one.
  case transport(kind: TransportFailureKind, underlying: (any Error)?)

  /// A Boolean value that indicates whether the request's deadline passed before a response
  /// arrived.
  ///
  /// This is a fact about the failure, not a retry decision, and it is the narrowest fact a retry
  /// policy can safely act on: a timed-out request is the one failure the server's application code
  /// is known not to have completed, so replaying it is as safe as a replay can be.
  /// ``RetryPolicy/retryable`` defaults to reading this property from ``FailedAttempt/failure``. A
  /// `408` or `504` is the server's answer
  /// delivered as a response, so it is an ``httpStatus(body:code:headers:)`` and not a timeout.
  public var isTimeout: Bool {
    if case .transport(kind: .timedOut, underlying: _) = self { true } else { false }
  }

  /// The HTTP status code when the failure is an ``httpStatus(body:code:headers:)``; `nil`
  /// otherwise.
  public var statusCode: Int? {
    if case .httpStatus(body: _, code: let code, headers: _) = self { code } else { nil }
  }

  /// The error a coder or transport reported, when the failure carries one.
  ///
  /// This collapses the three wrapping cases for logging or inspection. It is `nil` for
  /// ``cancelled``, for every ``httpStatus(body:code:headers:)``, and for a transport failure with
  /// no system error behind it.
  public var underlying: (any Error)? {
    switch self {
    case .cancelled, .httpStatus:
      nil
    case .decode(let underlying), .encode(let underlying):
      underlying
    case .transport(kind: _, let underlying):
      underlying
    }
  }
}

extension TransportError: CustomStringConvertible {
  /// A one-line summary that is safe to log.
  ///
  /// A status failure is reduced to its code and body byte count. The body may be an error envelope
  /// that echoes credentials, and the header fields may carry `Set-Cookie` or an authorization
  /// challenge, so neither is ever printed. A wrapped error is included by its own description.
  public var description: String {
    switch self {
    case .cancelled:
      "cancelled"
    case .decode(let underlying):
      "decode failed: \(underlying)"
    case .encode(let underlying):
      "encode failed: \(underlying)"
    case .httpStatus(let body, let code, headers: _):
      "HTTP \(code) with \(body.count) body bytes"
    case .transport(let kind, let underlying):
      if let underlying {
        "transport failure (\(kind)): \(underlying)"
      } else {
        "transport failure (\(kind))"
      }
    }
  }
}
