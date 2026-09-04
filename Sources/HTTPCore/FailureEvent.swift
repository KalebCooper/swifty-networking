// `Data` and `URL` are the only Foundation types this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTypes

/// How one send failed, reported in place of a ``ResponseEvent`` whenever a send ends in a
/// ``TransportError`` instead of a response.
///
/// A failure here is that send's own outcome, not the logical request's verdict. A send that fails
/// retryably is reported and then followed by a fresh ``RequestEvent`` for the next attempt, so an
/// observer counting failures counts sends unless it also reads ``attempt``.
///
/// Two outcomes are not failures for this purpose. A status the server returned arrives as a
/// ``ResponseEvent``, however the client's own policy goes on to treat it, and a body that failed
/// to decode reaches only the caller that asked for the decoding.
///
/// The event carries no credential and no header fields. ``bodyPreview`` is the one slot for bytes,
/// filled only when an observer asked for them through ``TransportObserver/bodyPreviewLimit``.
public struct FailureEvent: Sendable {
  /// Which attempt the failed send belongs to, counting from `1` for the first one.
  public var attempt: Int

  /// A Boolean value that indicates whether the client attached a credential to the attempt that
  /// failed.
  ///
  /// It separates an authorization failure from a request that never carried a credential.
  public var authAttached: Bool

  /// The leading bytes of the body involved in the failure, truncated to the observer's declared
  /// limit; `nil` when no observer asked for a preview, which is the default.
  ///
  /// A failure that never produced a response has no body to preview, so it is `nil` there whatever
  /// an observer asked for. The cut is by byte count, so a preview of textual content can end
  /// mid-character. Decode it leniently instead of assuming a whole scalar at the boundary.
  public var bodyPreview: Data?

  /// The identifier shared by every event belonging to one logical request, retries included.
  ///
  /// The value is opaque to the package: it is carried and never parsed.
  public var correlationID: String

  /// How long the failed send took, from the moment the client called the transport to the moment
  /// the failure surfaced.
  ///
  /// The measurement is that send's own elapsed time, never a running total: not the time already
  /// spent on earlier sends or hops, and not the waiting in between.
  public var duration: Duration

  /// The failure the attempt produced.
  ///
  /// ``TransportError/description`` is safe to record. The failure's payload is whatever a
  /// transport or a coder threw, and may say more than an observer wants to keep.
  public var failure: TransportError

  /// The method of the request that failed.
  public var method: HTTPRequest.Method

  /// The fully resolved target of the request that failed.
  public var url: URL

  /// Creates a failure event.
  ///
  /// - Parameters:
  ///   - attempt: The one-based attempt number.
  ///   - authAttached: Whether a credential was attached.
  ///   - bodyPreview: The size-capped body preview; defaults to `nil`, no preview.
  ///   - correlationID: The identifier shared across the logical request's events.
  ///   - duration: How long the failed send took.
  ///   - failure: The failure the attempt produced.
  ///   - method: The request method.
  ///   - url: The fully resolved request target.
  public init(
    attempt: Int, authAttached: Bool, bodyPreview: Data? = nil, correlationID: String,
    duration: Duration, failure: TransportError, method: HTTPRequest.Method, url: URL
  ) {
    self.attempt = attempt
    self.authAttached = authAttached
    self.bodyPreview = bodyPreview
    self.correlationID = correlationID
    self.duration = duration
    self.failure = failure
    self.method = method
    self.url = url
  }
}
