/// What ``RetryPolicy/retryable`` is asked about: the failure an attempt produced, which attempt it
/// was, and how long the request has been running.
///
/// The client builds one value per failed attempt and offers it to the predicate before any
/// waiting, and only while attempts remain. ``failure`` is what the attempt threw, a status failure
/// included, since the client interprets the status inside the attempt. ``attempt`` and
/// ``elapsed`` let a predicate reason about more than the failure: give up sooner on a slow
/// endpoint, or budget the whole request instead of counting attempts.
///
/// ```swift
/// let policy = RetryPolicy(
///   backoff: BackoffSchedule(delays: [.milliseconds(100), .milliseconds(400)]),
///   maxAttempts: 5,
///   retryable: { failed in
///     failed.failure.isTimeout && failed.elapsed < .seconds(10)
///   }
/// )
/// ```
///
/// An attempt is the whole exchange: one send, every redirect hop after it, and the `401`
/// refresh-and-replay when one happens. See <doc:RequestPolicies>.
public struct FailedAttempt: Sendable {
  /// The one-based ordinal of the attempt that failed; `1` is the first send.
  public var attempt: Int

  /// How long the request has been running on the client's clock, measured from just before the
  /// first attempt was sent to the moment this attempt failed.
  ///
  /// It covers every send, redirect hop, and `401` replay so far, and every wait between attempts,
  /// a `Retry-After` wait included, and it grows from one value to the next. What it never covers
  /// is the request's deadline: when a ``HTTPClient/timeout`` passes, the request fails with
  /// ``TransportFailureKind/timedOut`` and the predicate is not asked, so a wait the deadline cut
  /// short is never reported here.
  public var elapsed: Duration

  /// What the attempt threw: a transport failure, or a status outside `2xx` as
  /// ``TransportError/httpStatus(body:code:headers:)``.
  ///
  /// The default predicate reads ``TransportError/isTimeout`` from it. Never
  /// ``TransportError/cancelled``: a cancelled request is not offered for retry.
  public var failure: TransportError

  /// Creates a description of a failed attempt.
  ///
  /// The client builds these itself. Build one by hand to exercise a predicate in a test.
  ///
  /// - Parameters:
  ///   - attempt: The one-based ordinal of the attempt that failed.
  ///   - elapsed: How long the request had been running when the attempt failed.
  ///   - failure: What the attempt threw.
  public init(attempt: Int, elapsed: Duration, failure: TransportError) {
    self.attempt = attempt
    self.elapsed = elapsed
    self.failure = failure
  }
}
