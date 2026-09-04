// `URL` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTypes

/// What a client is about to send, reported once per send before the transport is called.
///
/// This is the only record of a send that never comes back: a request cancelled or lost in the
/// network produces this event and then a ``FailureEvent``, with no response in between. It
/// therefore carries enough to identify the send on its own.
///
/// Nothing here is a credential. ``authAttached`` records that the client attached one, never what
/// it was, and no header fields are included. A credential encoded into the request's query string
/// appears in ``url`` as it would in any other record of the request.
public struct RequestEvent: Hashable, Sendable {
  /// Which attempt this send belongs to, counting from `1` for the first one.
  ///
  /// A retried request reports a new event per attempt, all sharing one ``correlationID``. The
  /// ordinal counts attempts, not sends, so an attempt that refreshes a credential and replays its
  /// request reports two events under the same number.
  public var attempt: Int

  /// A Boolean value that indicates whether the client attached a credential to this attempt.
  ///
  /// `false` covers both an anonymous request and one whose credential was unavailable.
  public var authAttached: Bool

  /// The identifier shared by every event belonging to one logical request, retries included.
  ///
  /// The value is opaque to the package: it is carried and never parsed, so a client is free to
  /// generate one or adopt an identifier assigned upstream.
  public var correlationID: String

  /// The request method.
  public var method: HTTPRequest.Method

  /// The fully resolved request target.
  ///
  /// Resolution has already happened, so this is what the transport receives, not the relative path
  /// you wrote.
  public var url: URL

  /// Creates a request event.
  ///
  /// - Parameters:
  ///   - attempt: The one-based attempt number.
  ///   - authAttached: Whether a credential was attached.
  ///   - correlationID: The identifier shared across the logical request's events.
  ///   - method: The request method.
  ///   - url: The fully resolved request target.
  public init(
    attempt: Int, authAttached: Bool, correlationID: String, method: HTTPRequest.Method, url: URL
  ) {
    self.attempt = attempt
    self.authAttached = authAttached
    self.correlationID = correlationID
    self.method = method
    self.url = url
  }
}
