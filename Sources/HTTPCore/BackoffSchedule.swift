/// A table of delays that says how long to wait between one failed attempt and the next.
///
/// The schedule is a step function of the attempt number. The table's first entry is the wait after
/// the first attempt failed, the second entry the wait after the second, and the last entry repeats
/// for every attempt beyond the table. A short table therefore describes an unbounded number of
/// retries: the schedule says how long to wait, and ``RetryPolicy/maxAttempts`` says when to stop.
///
/// ```swift
/// let schedule = BackoffSchedule(
///   delays: [.milliseconds(100), .milliseconds(400), .seconds(2)]
/// )
/// schedule.delay(forAttempt: 1)  // 100 ms
/// schedule.delay(forAttempt: 9)  // 2 s, the last entry repeating
/// ```
///
/// The delays are written as an `InlineArray`, a fixed-size value whose length the compiler knows.
/// The initializer captures the table once, and the schedule then answers every lookup without
/// allocating again.
public struct BackoffSchedule: Sendable {
  /// The jitter function applied to each delay the table yields.
  private let jitter: @Sendable (Duration) -> Duration

  /// The table lookup, closed over the delays.
  private let tabulatedDelay: @Sendable (Int) -> Duration

  /// A schedule that never waits, for a bounded number of immediate retries.
  public static let zero = BackoffSchedule(delays: [])

  /// Creates a schedule from a table of delays.
  ///
  /// - Parameters:
  ///   - delays: The wait after each attempt, in attempt order. The last entry repeats past the end
  ///     of the table, and an empty table never waits.
  ///   - jitter: A transform applied to every delay the table yields, called once per
  ///     ``delay(forAttempt:)``. The default is the identity, so a schedule's delays are exactly
  ///     the values written and a test can assert them. Supply a function to spread a herd of
  ///     clients whose retries would otherwise land together; the schedule adds no randomness on
  ///     its own.
  public init<let N: Int>(
    delays: InlineArray<N, Duration>,
    jitter: @escaping @Sendable (Duration) -> Duration = { $0 }
  ) {
    self.tabulatedDelay = { attempt in
      guard !delays.isEmpty else { return .zero }
      // The attempt number is clamped before the index is derived from it, so an extreme number
      // saturates instead of overflowing on its way to the table.
      return delays[min(max(attempt, 1), delays.count) - 1]
    }
    self.jitter = jitter
  }

  /// Returns the delay to wait after the given attempt failed, before making the next one.
  ///
  /// Attempts are numbered from one, so the attempt that just failed selects the table entry of the
  /// same ordinal. The function is total: an attempt number past the table's end answers with the
  /// last entry, one at or below the first answers with the first, and an empty table answers
  /// `.zero`. Deciding when to stop retrying belongs to ``RetryPolicy``.
  ///
  /// - Parameter attempt: The one-based number of the attempt that just failed.
  /// - Returns: The delay to wait, with the schedule's jitter applied.
  public func delay(forAttempt attempt: Int) -> Duration {
    jitter(tabulatedDelay(attempt))
  }
}
