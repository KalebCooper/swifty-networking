import HTTPCore
import HTTPTesting
import Testing

/// A provider that returns a fixed token and reports no expiry.
private struct StaticToken: TokenProvider {
  let token: String?

  func currentToken() -> String? { token }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct TokenProviderTests {
  @Test("A provider that does not track expiry reports nil by default")
  func expiryDefaultsToNil() {
    let provider = StaticToken(token: "t")
    #expect(provider.currentToken() == "t")
    #expect(provider.timeUntilExpiry == nil)
    #expect(StaticToken(token: nil).currentToken() == nil)
  }

  @Test("The expiry default is a requirement, so an erased provider reports its own value")
  func expiryDispatchesThroughExistential() {
    let providers: [any TokenProvider] = [
      StaticToken(token: "t"),
      RecordingTokenProvider(timeUntilExpiry: .seconds(5), token: "t"),
    ]
    #expect(providers.map(\.timeUntilExpiry) == [nil, .seconds(5)])
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct TokenRefresherTests {
  @Test("A refresher is usable through an existential, the shape a client stores it as")
  func refresherIsUsableErased() async throws {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t")])
    let refresher: any TokenRefresher = tokens
    try await refresher.refresh()
    #expect(tokens.currentToken() == "t")
  }
}
