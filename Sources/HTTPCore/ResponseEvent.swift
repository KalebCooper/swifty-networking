// `Data` and `URL` are the only Foundation types this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTypes

/// A response as it arrived for one send, reported after the transport returned.
///
/// Every response reaches an observer here, whatever its status. A transport treats a non-2xx as a
/// response and not a failure, so a `404` or a `500` is reported through this event, and becomes
/// a ``FailureEvent`` only if the client's own policy turns the status into an error.
///
/// ``bodyPreview`` is absent unless an observer asked for bytes through
/// ``TransportObserver/bodyPreviewLimit``.
public struct ResponseEvent: Hashable, Sendable {
  /// Which attempt the send that produced this response belongs to, counting from `1` for the first
  /// one.
  public var attempt: Int

  /// A Boolean value that indicates whether the client attached a credential to the attempt that
  /// produced this response.
  public var authAttached: Bool

  /// The leading bytes of the response body, truncated to the observer's declared limit; `nil` when
  /// no observer asked for a preview, which is the default.
  ///
  /// The cut is by byte count, so a preview of textual content can end mid-character. Decode it
  /// leniently instead of assuming a whole scalar at the boundary.
  public var bodyPreview: Data?

  /// The identifier shared by every event belonging to one logical request, retries included.
  ///
  /// The value is opaque to the package: it is carried and never parsed.
  public var correlationID: String

  /// How long this send took, from the moment the client called the transport to the moment the
  /// response came back.
  ///
  /// The measurement is that send's own elapsed time, never a running total: a redirect hop and a
  /// `401` replay each report their own, and the waiting between attempts belongs to whoever
  /// drives the retry loop.
  public var duration: Duration

  /// The method of the request that produced this response.
  public var method: HTTPRequest.Method

  /// The status the server returned.
  ///
  /// A failure status arrives here, not in a ``FailureEvent``: the server answered, which is what
  /// this event reports.
  public var status: HTTPResponse.Status

  /// The fully resolved target of the request that produced this response.
  public var url: URL

  /// Creates a response event.
  ///
  /// - Parameters:
  ///   - attempt: The one-based attempt number.
  ///   - authAttached: Whether a credential was attached.
  ///   - bodyPreview: The size-capped body preview; defaults to `nil`, no preview.
  ///   - correlationID: The identifier shared across the logical request's events.
  ///   - duration: How long this send took.
  ///   - method: The request method.
  ///   - status: The status the server returned.
  ///   - url: The fully resolved request target.
  public init(
    attempt: Int, authAttached: Bool, bodyPreview: Data? = nil, correlationID: String,
    duration: Duration, method: HTTPRequest.Method, status: HTTPResponse.Status, url: URL
  ) {
    self.attempt = attempt
    self.authAttached = authAttached
    self.bodyPreview = bodyPreview
    self.correlationID = correlationID
    self.duration = duration
    self.method = method
    self.status = status
    self.url = url
  }
}
