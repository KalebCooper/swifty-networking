import HTTPCore
import HTTPTesting
import Testing

/// Runs `body` and returns the typed failure it threw, or `nil` when it succeeded.
private func failure<Value>(
  of body: () async throws -> Value,
  sourceLocation: SourceLocation = #_sourceLocation
) async -> TransportError? {
  do {
    _ = try await body()
    return nil
  } catch let error as TransportError {
    return error
  } catch {
    Issue.record("expected a TransportError, got \(error)", sourceLocation: sourceLocation)
    return nil
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct RecordingTokenProviderCredentialTests {
  @Test("A source reports the token and the remaining lifetime it was seeded with")
  func seededCredentialIsReported() {
    let tokens = RecordingTokenProvider(timeUntilExpiry: .seconds(60), token: "t1")

    #expect(tokens.currentToken() == "t1")
    #expect(tokens.timeUntilExpiry == .seconds(60))
    #expect(tokens.refreshes == 0)
  }

  @Test("A source seeded with nothing is unauthenticated and reports no lifetime")
  func emptySourceIsUnauthenticated() {
    let tokens = RecordingTokenProvider()

    #expect(tokens.currentToken() == nil)
    #expect(tokens.timeUntilExpiry == nil)
  }

  @Test("install(timeUntilExpiry:token:) replaces the credential and the lifetime together")
  func installReplacesBoth() {
    let tokens = RecordingTokenProvider(timeUntilExpiry: .seconds(60), token: "t1")

    tokens.install(timeUntilExpiry: .seconds(-5), token: "t2")

    #expect(tokens.currentToken() == "t2")
    #expect(tokens.timeUntilExpiry == .seconds(-5))
  }

  @Test("An installed lifetime defaults to unknown, so an install alone opts out of expiry")
  func installDefaultsToAnUnknownLifetime() {
    let tokens = RecordingTokenProvider(timeUntilExpiry: .seconds(60), token: "t1")

    tokens.install(token: "t2")

    #expect(tokens.timeUntilExpiry == nil)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct RecordingTokenProviderRefreshTests {
  @Test("A refresh installs the next seeded token with the seeded refresh lifetime")
  func refreshInstallsTheNextToken() async throws {
    let tokens = RecordingTokenProvider(
      refreshLifetime: .seconds(90),
      refreshOutcomes: [.success("t2"), .success("t3")],
      timeUntilExpiry: .zero,
      token: "t1"
    )

    try await tokens.refresh()

    #expect(tokens.currentToken() == "t2")
    #expect(tokens.timeUntilExpiry == .seconds(90))

    try await tokens.refresh()

    #expect(tokens.currentToken() == "t3")
  }

  @Test("A seeded failure is thrown as it was seeded and leaves the credential untouched")
  func seededFailureLeavesTheCredentialUntouched() async {
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.failure(.transport(kind: .connectivity, underlying: nil))],
      timeUntilExpiry: .seconds(3),
      token: "t1"
    )

    let error = await failure(of: { try await tokens.refresh() })

    guard case .transport(kind: .connectivity, underlying: nil)? = error else {
      Issue.record("expected the seeded connectivity failure, got \(String(describing: error))")
      return
    }
    #expect(tokens.currentToken() == "t1")
    #expect(tokens.timeUntilExpiry == .seconds(3))
  }

  @Test("Every refresh is counted, the ones that threw as well as the ones that installed")
  func refreshesCountsSuccessesAndFailures() async {
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.success("t2"), .failure(.transport(kind: .timedOut, underlying: nil))],
      token: "t1"
    )

    _ = await failure(of: { try await tokens.refresh() })
    _ = await failure(of: { try await tokens.refresh() })

    #expect(tokens.refreshes == 2)
    #expect(tokens.currentToken() == "t2")
  }

  @Test("A refresh past the last seeded outcome fails with the source's own reason")
  func exhaustedQueueIsNamed() async {
    let tokens = RecordingTokenProvider(token: "t1")

    let error = await failure(of: { try await tokens.refresh() })

    guard case .transport(kind: let kind, underlying: let underlying)? = error else {
      Issue.record("expected a transport failure, got \(String(describing: error))")
      return
    }
    #expect(kind == .other)
    #expect(underlying as? RecordingTokenProviderFailure == .noSeededOutcome)
    #expect(tokens.refreshes == 1)
    #expect(tokens.currentToken() == "t1")
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct RecordingTokenProviderConcurrencyTests {
  @Test("Concurrent refreshes take each seeded outcome exactly once")
  func concurrentRefreshesTakeEachOutcomeOnce() async {
    let seeded = 8
    let callers = 12
    let tokens = RecordingTokenProvider(
      refreshOutcomes: Array(repeating: .success("t2"), count: seeded), token: "t1")

    let failures = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<callers {
        group.addTask {
          await failure(of: { try await tokens.refresh() })?.underlying
            as? RecordingTokenProviderFailure == .noSeededOutcome
        }
      }
      return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
    }

    #expect(failures == callers - seeded)
    #expect(tokens.refreshes == callers)
    #expect(tokens.currentToken() == "t2")
  }

  @Test("A source is safe to read from many tasks at once")
  func sourceIsReadableConcurrently() async {
    let tokens = RecordingTokenProvider(token: "t1")

    let read = await withTaskGroup(of: String?.self) { group in
      for _ in 0..<8 {
        group.addTask { tokens.currentToken() }
      }
      return await group.reduce(into: [String?]()) { $0.append($1) }
    }

    #expect(read == Array(repeating: "t1", count: 8))
  }
}
