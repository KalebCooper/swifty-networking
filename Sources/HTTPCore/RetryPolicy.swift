/// A value that describes whether a failed request is sent again, how often, and after what wait.
///
/// The policy is three independent settings: ``backoff`` says how long to wait, ``maxAttempts``
/// says when to give up, and ``retryable`` says which failures are worth another send. Change one
/// without disturbing the others.
///
/// The predicate is offered a ``FailedAttempt``: the failure, the attempt's ordinal, and how long
/// the request has been running, so it can budget time as well as pick failures. The default is
/// narrow, retrying timeouts alone; widen it where you know your own endpoints are idempotent. See
/// <doc:RequestPolicies> for what an attempt covers and when the server's `Retry-After` replaces
/// the schedule's delay.
///
/// ```swift
/// let policy = RetryPolicy(
///   backoff: BackoffSchedule(delays: [.milliseconds(100), .milliseconds(400)]),
///   maxAttempts: 3,
///   retryable: { $0.failure.isTimeout || $0.failure.statusCode == 503 }
/// )
/// ```
///
/// A policy carries closures, so it is a value without being equatable: two policies built the same
/// way behave identically but cannot be compared.
public struct RetryPolicy: Sendable {
  /// How long to wait between attempts.
  public var backoff: BackoffSchedule

  /// The total number of attempts, counting the first send.
  ///
  /// A value of `1` disables retrying. A client always makes one attempt, so a value below `1`
  /// means the same as `1`.
  public var maxAttempts: Int

  /// A predicate that reports whether a failed attempt is worth another.
  ///
  /// The client calls it with a ``FailedAttempt`` describing the attempt that just failed, before
  /// any waiting, and only while attempts remain. The failure it carries is a status failure as
  /// well as a transport one, because the client interprets the status inside the attempt; the
  /// ordinal and the elapsed time let a predicate stop on a budget rather than a count. When the
  /// answer is yes, the wait that follows is the server's `Retry-After` when the failure carried
  /// one in seconds, and ``backoff``'s delay otherwise.
  public var retryable: @Sendable (FailedAttempt) -> Bool

  /// A policy that never retries: one attempt, no waiting.
  public static let disabled = RetryPolicy(backoff: .zero, maxAttempts: 1)

  /// Creates a retry policy.
  ///
  /// - Parameters:
  ///   - backoff: The schedule of delays between attempts.
  ///   - maxAttempts: The total number of attempts including the first; `1` disables retrying.
  ///   - retryable: The predicate that decides whether a failed attempt earns another; defaults to
  ///     ``TransportError/isTimeout`` of the attempt's failure. A `5xx` and every other transport
  ///     failure are excluded until you opt them in.
  public init(
    backoff: BackoffSchedule,
    maxAttempts: Int,
    retryable: @escaping @Sendable (FailedAttempt) -> Bool = { $0.failure.isTimeout }
  ) {
    self.backoff = backoff
    self.maxAttempts = maxAttempts
    self.retryable = retryable
  }
}
