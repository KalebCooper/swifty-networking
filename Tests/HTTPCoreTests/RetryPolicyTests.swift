import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Compile-time check that a type is `Sendable`.
private func requireSendable<T: Sendable>(_: T.Type) {}

/// An error the tests pass as an underlying error.
private struct ProbeError: Error {}

/// A failed attempt around `failure`, first attempt and no time elapsed unless a test says otherwise.
private func failed(
  _ failure: TransportError, attempt: Int = 1, elapsed: Duration = .zero
) -> FailedAttempt {
  FailedAttempt(attempt: attempt, elapsed: elapsed, failure: failure)
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct RetryPolicyTests {
  static let predicateTable: [(failure: TransportError, isRetryable: Bool)] = [
    (.cancelled, false),
    (.decode(underlying: ProbeError()), false),
    (.encode(underlying: ProbeError()), false),
    (.httpStatus(body: Data(), code: 408, headers: [:]), false),
    (.httpStatus(body: Data("{}".utf8), code: 500, headers: [.retryAfter: "1"]), false),
    (.httpStatus(body: Data(), code: 503, headers: [:]), false),
    (.httpStatus(body: Data(), code: 504, headers: [:]), false),
    (.transport(kind: .badURL, underlying: nil), false),
    (.transport(kind: .connectivity, underlying: ProbeError()), false),
    (.transport(kind: .other, underlying: ProbeError()), false),
    (.transport(kind: .timedOut, underlying: nil), true),
    (.transport(kind: .timedOut, underlying: ProbeError()), true),
  ]

  @Test("The default predicate retries a timeout and nothing else", arguments: predicateTable)
  func defaultPredicateMatchesTable(failure: TransportError, isRetryable: Bool) {
    let policy = RetryPolicy(backoff: .zero, maxAttempts: 3)
    #expect(policy.retryable(failed(failure)) == isRetryable)
  }

  static let contextTable: [(attempt: Int, elapsed: Duration)] = [
    (1, .zero), (2, .milliseconds(1)), (50, .seconds(3_600)), (Int.max, .seconds(-1)),
  ]

  @Test(
    "The default predicate reads the failure alone, whatever the ordinal and the elapsed time",
    arguments: contextTable)
  func defaultPredicateIgnoresTheContext(attempt: Int, elapsed: Duration) {
    let policy = RetryPolicy(backoff: .zero, maxAttempts: 3)
    let timeout = TransportError.transport(kind: .timedOut, underlying: nil)
    let connectivity = TransportError.transport(kind: .connectivity, underlying: nil)
    #expect(policy.retryable(failed(timeout, attempt: attempt, elapsed: elapsed)))
    #expect(!policy.retryable(failed(connectivity, attempt: attempt, elapsed: elapsed)))
  }

  @Test("A caller's own predicate replaces the default entirely")
  func customPredicateReplacesTheDefault() {
    let policy = RetryPolicy(backoff: .zero, maxAttempts: 2) { $0.failure.statusCode == 503 }
    #expect(policy.retryable(failed(.httpStatus(body: Data(), code: 503, headers: [:]))))
    #expect(!policy.retryable(failed(.transport(kind: .timedOut, underlying: nil))))
  }

  @Test("A predicate sees the ordinal and the elapsed time it was handed")
  func customPredicateSeesTheContext() {
    let policy = RetryPolicy(backoff: .zero, maxAttempts: 9) {
      $0.attempt < 3 && $0.elapsed < .seconds(1)
    }
    let timeout = TransportError.transport(kind: .timedOut, underlying: nil)
    #expect(policy.retryable(failed(timeout, attempt: 2, elapsed: .milliseconds(999))))
    #expect(!policy.retryable(failed(timeout, attempt: 3, elapsed: .milliseconds(999))))
    #expect(!policy.retryable(failed(timeout, attempt: 2, elapsed: .seconds(1))))
  }

  @Test("The disabled policy is one attempt with no waiting")
  func disabledPolicyNeverRetries() {
    #expect(RetryPolicy.disabled.maxAttempts == 1)
    #expect(RetryPolicy.disabled.backoff.delay(forAttempt: 1) == .zero)
  }

  @Test("Every knob is settable after the fact")
  func knobsAreSettable() {
    var policy = RetryPolicy.disabled
    policy.backoff = BackoffSchedule(delays: [.milliseconds(50)])
    policy.maxAttempts = 4
    policy.retryable = { _ in true }

    #expect(policy.backoff.delay(forAttempt: 1) == .milliseconds(50))
    #expect(policy.maxAttempts == 4)
    #expect(policy.retryable(failed(.cancelled)))
  }

  @Test("A policy crosses isolation boundaries freely")
  func policyIsSendable() {
    requireSendable(RetryPolicy.self)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct FailedAttemptTests {
  @Test("A failed attempt carries the ordinal, the elapsed time, and the failure it was given")
  func carriesWhatItWasGiven() {
    let failed = FailedAttempt(
      attempt: 3, elapsed: .milliseconds(1_250),
      failure: .httpStatus(body: Data("{}".utf8), code: 503, headers: [.retryAfter: "1"]))
    #expect(failed.attempt == 3)
    #expect(failed.elapsed == .milliseconds(1_250))
    #expect(failed.failure.statusCode == 503)
  }

  @Test("Every field is settable after the fact")
  func fieldsAreSettable() {
    var failed = FailedAttempt(attempt: 1, elapsed: .zero, failure: .cancelled)
    failed.attempt = 2
    failed.elapsed = .seconds(4)
    failed.failure = .transport(kind: .timedOut, underlying: nil)
    #expect(failed.attempt == 2)
    #expect(failed.elapsed == .seconds(4))
    #expect(failed.failure.isTimeout)
  }

  @Test("A failed attempt crosses isolation boundaries freely")
  func failedAttemptIsSendable() {
    requireSendable(FailedAttempt.self)
  }
}
