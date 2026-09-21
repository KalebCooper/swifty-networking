import HTTPCore
import HTTPTesting
import Testing

@Suite("Authentication", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct AuthenticationTests {
  @Test("a Basic credential is the base64 of the user name, a colon, and the password")
  func basicCredential() {
    #expect(
      Authentication.basicCredential(password: "open sesame", username: "Aladdin")
        == "QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
  }

  @Test("a colon in the password is encoded like any other character")
  func basicCredentialWithAColonInThePassword() {
    #expect(
      Authentication.basicCredential(password: "pa:ss", username: "user") == "dXNlcjpwYTpzcw==")
  }

  @Test("a colon in the user name is encoded as given, unchecked")
  func basicCredentialWithAColonInTheUserName() {
    #expect(
      Authentication.basicCredential(password: "pass", username: "us:er") == "dXM6ZXI6cGFzcw==")
  }

  @Test("an empty user name or an empty password is encoded as given")
  func basicCredentialWithAnEmptyHalf() {
    #expect(Authentication.basicCredential(password: "", username: "") == "Og==")
    #expect(Authentication.basicCredential(password: "", username: "user") == "dXNlcjo=")
  }

  @Test("a password outside ASCII is encoded as UTF-8")
  func basicCredentialWithANonASCIIPassword() {
    #expect(
      Authentication.basicCredential(password: "123£", username: "test") == "dGVzdDoxMjPCow==")
  }

  @Test("the defaults carry no refresher, enable replay, and leave proactive refresh off")
  func defaults() {
    let authentication = Authentication(provider: RecordingTokenProvider(token: "t1"))
    #expect(authentication.provider.currentToken() == "t1")
    #expect(authentication.refresher == nil)
    #expect(authentication.refreshThreshold == nil)
    #expect(authentication.replayOn401)
  }

  @Test("the default scheme is bearer")
  func defaultScheme() {
    let authentication = Authentication(provider: RecordingTokenProvider(token: "t1"))
    #expect(authentication.scheme == .bearer)
  }

  @Test("the rules can be narrowed on a copy without touching the original")
  func rulesNarrowOnACopy() {
    let tokens = RecordingTokenProvider(token: "t1")
    let original = Authentication(
      provider: tokens, refresher: tokens, refreshThreshold: .seconds(30))
    var narrowed = original
    narrowed.refreshThreshold = .seconds(5)
    narrowed.replayOn401 = false

    #expect(narrowed.refreshThreshold == .seconds(5))
    #expect(!narrowed.replayOn401)
    #expect(narrowed.refresher != nil)
    #expect(original.refreshThreshold == .seconds(30))
    #expect(original.replayOn401)
  }

}

@Suite("Authentication refresh cancellation", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct AuthenticationRefreshTests {
  @Test("All cancelled waiters leave while credential rotation still completes")
  func allCancelledWaitersLeaveWhileCredentialRotationStillCompletes() async throws {
    let clock = RecordingClock()
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("new")], token: "old")
    let refresher = ParkedRefresher(clock: clock, tokens: tokens)
    let authentication = Authentication(provider: tokens, refresher: refresher)
    let callers = (0..<4).map { _ in
      Task.immediate { try await authentication.refresh(replacing: "old") }
    }
    await clock.waitForPendingSleep()
    for caller in callers { caller.cancel() }
    for caller in callers {
      #expect(await caller.result.failureDescription == "cancelled")
    }
    #expect(clock.pendingSleeps == 1)
    #expect(tokens.currentToken() == "old")

    // An empty waiter table still represents the original rotation.
    let late = Task.immediate { try await authentication.refresh(replacing: "old") }
    clock.advanceAll()
    try await late.value
    #expect(tokens.currentToken() == "new")
    #expect(tokens.refreshes == 1)
    try await authentication.refresh(replacing: "old")
    #expect(tokens.refreshes == 1)
  }

  @Test("Cancellation racing completion settles each caller once", arguments: 0..<12)
  func cancellationRacingCompletionSettlesEachCallerOnce(iteration: Int) async throws {
    let clock = RecordingClock()
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("new")], token: "old")
    let authentication = Authentication(
      provider: tokens, refresher: ParkedRefresher(clock: clock, tokens: tokens))
    let caller = Task.immediate { try await authentication.refresh(replacing: "old") }
    let survivor = Task.immediate { try await authentication.refresh(replacing: "old") }
    await clock.waitForPendingSleep()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { caller.cancel() }
      group.addTask { clock.advanceAll() }
    }
    let result = await caller.result
    #expect(result.failureDescription == nil || result.failureDescription == "cancelled")
    try await survivor.value
    #expect(tokens.refreshes == 1)
    #expect(clock.pendingSleeps == 0)
  }

  @Test("Cancelled leaders and joiners leave before a shared refresh completes", arguments: [0, 1])
  func cancelledLeadersAndJoinersLeaveBeforeASharedRefreshCompletes(cancelledIndex: Int)
    async throws
  {
    let clock = RecordingClock()
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("new")], token: "old")
    let authentication = Authentication(
      provider: tokens, refresher: ParkedRefresher(clock: clock, tokens: tokens))
    let callers = (0..<2).map { _ in
      Task.immediate { try await authentication.refresh(replacing: "old") }
    }
    await clock.waitForPendingSleep()
    callers[cancelledIndex].cancel()
    #expect(await callers[cancelledIndex].result.failureDescription == "cancelled")
    #expect(clock.pendingSleeps == 1)
    #expect(tokens.currentToken() == "old")
    clock.advanceAll()
    try await callers[1 - cancelledIndex].value
    #expect(tokens.currentToken() == "new")
    #expect(tokens.refreshes == 1)
  }

  @Test("Failed refreshes reach all remaining waiters and permit a later refresh")
  func failedRefreshesReachAllRemainingWaitersAndPermitALaterRefresh() async throws {
    let clock = RecordingClock()
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.failure(.cancelled), .success("new")], token: "old")
    let authentication = Authentication(
      provider: tokens, refresher: ParkedRefresher(clock: clock, tokens: tokens))
    let callers = (0..<3).map { _ in
      Task.immediate { try await authentication.refresh(replacing: "old") }
    }
    await clock.waitForPendingSleep()
    clock.advanceAll()
    for caller in callers { #expect(await caller.result.failureDescription == "cancelled") }
    #expect(tokens.currentToken() == "old")
    let retry = Task.immediate { try await authentication.refresh(replacing: "old") }
    await clock.waitForPendingSleep()
    clock.advanceAll()
    try await retry.value
    #expect(tokens.refreshes == 2)
    #expect(tokens.currentToken() == "new")
  }

  @Test("Precancelled refresh calls never start credential rotation")
  func precancelledRefreshCallsNeverStartCredentialRotation() async {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("new")], token: "old")
    let authentication = Authentication(provider: tokens, refresher: tokens)
    let start = WebSocketRendezvous()
    let caller = Task.immediate {
      // Resume after cancellation, then enter authentication on the already-cancelled task.
      try? await start.arriveAndWait()
      try await authentication.refresh(replacing: "old")
    }
    caller.cancel()
    #expect(await caller.result.failureDescription == "cancelled")
    #expect(tokens.refreshes == 0)
    #expect(tokens.currentToken() == "old")
  }

}

private struct ParkedRefresher: TokenRefresher {
  let clock: RecordingClock
  let tokens: RecordingTokenProvider

  func refresh() async throws(TransportError) {
    do {
      try await clock.sleep(for: .seconds(1))
    } catch {
      throw .cancelled
    }
    try await tokens.refresh()
  }
}

extension Result where Success == Void, Failure == any Error {
  fileprivate var failureDescription: String? {
    switch self {
    case .failure(let error): String(describing: error)
    case .success: nil
    }
  }
}
