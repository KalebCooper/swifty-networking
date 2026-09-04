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

/// An error the tests pass as an underlying error, compared by `id`.
private struct ProbeError: Error, Equatable {
  let id: Int
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct TransportErrorTests {
  static let accessorTable:
    [(error: TransportError, statusCode: Int?, isTimeout: Bool, hasUnderlying: Bool)] = [
      (.cancelled, nil, false, false),
      (.decode(underlying: ProbeError(id: 1)), nil, false, true),
      (.encode(underlying: ProbeError(id: 2)), nil, false, true),
      (.httpStatus(body: Data(), code: 401, headers: [:]), 401, false, false),
      (.httpStatus(body: Data("{}".utf8), code: 408, headers: [:]), 408, false, false),
      (.httpStatus(body: Data(), code: 500, headers: [.retryAfter: "1"]), 500, false, false),
      (.httpStatus(body: Data(), code: 504, headers: [:]), 504, false, false),
      (.transport(kind: .badURL, underlying: nil), nil, false, false),
      (.transport(kind: .connectivity, underlying: ProbeError(id: 3)), nil, false, true),
      (.transport(kind: .other, underlying: ProbeError(id: 4)), nil, false, true),
      (.transport(kind: .timedOut, underlying: nil), nil, true, false),
      (.transport(kind: .timedOut, underlying: ProbeError(id: 5)), nil, true, true),
    ]

  @Test("Each accessor reports the documented value for every case", arguments: accessorTable)
  func accessorsMatchTable(
    error: TransportError, statusCode: Int?, isTimeout: Bool, hasUnderlying: Bool
  ) {
    #expect(error.statusCode == statusCode)
    #expect(error.isTimeout == isTimeout)
    #expect((error.underlying != nil) == hasUnderlying)
  }

  @Test("The underlying accessor returns the wrapped error itself, not a copy or a wrapper")
  func underlyingIsTheWrappedError() {
    let probe = ProbeError(id: 9)
    #expect(TransportError.decode(underlying: probe).underlying as? ProbeError == probe)
    #expect(TransportError.encode(underlying: probe).underlying as? ProbeError == probe)
    #expect(
      TransportError.transport(kind: .other, underlying: probe).underlying as? ProbeError == probe
    )
  }

  @Test("A retry predicate reading isTimeout from the failed attempt answers as isTimeout does")
  func isTimeoutIsAPredicate() {
    let policy = RetryPolicy(backoff: .zero, maxAttempts: 2) { $0.failure.isTimeout }
    let failures: [TransportError] = [
      .transport(kind: .timedOut, underlying: nil),
      .transport(kind: .connectivity, underlying: nil),
      .httpStatus(body: Data(), code: 503, headers: [:]),
    ]
    let answers = failures.map { failure in
      policy.retryable(FailedAttempt(attempt: 1, elapsed: .zero, failure: failure))
    }
    #expect(answers == [true, false, false])
    #expect(answers == failures.map(\.isTimeout))
  }

  @Test("A status failure's description never prints the body or a header field")
  func descriptionNeverLeaksBodyOrHeaders() {
    let error = TransportError.httpStatus(
      body: Data("secret-envelope".utf8),
      code: 401,
      headers: [.setCookie: "session=topsecret", .wwwAuthenticate: "Bearer realm=\"x\""]
    )
    let description = error.description

    #expect(description.contains("401"))
    #expect(description.contains("15"))
    #expect(!description.contains("secret-envelope"))
    #expect(!description.contains("session"))
    #expect(!description.contains("topsecret"))
    #expect(!description.contains("Bearer"))
    #expect(!description.contains("realm"))
  }

  @Test("Descriptions name the case and the failure kind")
  func descriptionsNameTheCase() {
    #expect(TransportError.cancelled.description == "cancelled")
    #expect(
      TransportError.transport(kind: .timedOut, underlying: nil).description
        == "transport failure (timedOut)"
    )
    #expect(
      TransportError.transport(kind: .connectivity, underlying: ProbeError(id: 7)).description
        .hasPrefix("transport failure (connectivity): ")
    )
    #expect(
      TransportError.decode(underlying: ProbeError(id: 8)).description.hasPrefix("decode failed: "))
    #expect(
      TransportError.encode(underlying: ProbeError(id: 8)).description.hasPrefix("encode failed: "))
  }

  @Test(
    "A typed throw is matched by a single-case catch pattern with the compiler checking the rest")
  func typedThrowMatchesCasePattern() {
    func fail() throws(TransportError) {
      throw .httpStatus(body: Data(), code: 401, headers: [:])
    }

    var sawUnauthorized = false
    do {
      try fail()
    } catch .httpStatus(body: _, code: 401, headers: _) {
      sawUnauthorized = true
    } catch {
      Issue.record("expected the 401 pattern to match, got \(error)")
    }
    #expect(sawUnauthorized)
  }

  @Test("The failure kinds are the four a policy distinguishes")
  func failureKindsAreDistinct() {
    let kinds: Set<TransportFailureKind> = [.badURL, .connectivity, .other, .timedOut]
    #expect(kinds.count == 4)
  }

  @Test("The error and its failure kind cross isolation boundaries freely")
  func errorTypesAreSendable() {
    requireSendable(TransportError.self)
    requireSendable(TransportFailureKind.self)
  }
}
