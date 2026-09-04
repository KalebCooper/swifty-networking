import HTTPCore
import Synchronization

/// A ``/HTTPCore/TokenProvider`` and a ``/HTTPCore/TokenRefresher`` in one, holding the credential a
/// test seeded and recording every refresh the client asked for.
///
/// The client reads the credential through the provider half and obtains a new one through the
/// refresher half, so an ``/HTTPCore/Authentication`` over the same instance as both is the whole
/// configuration for an authenticated test.
///
/// ```swift
/// @Test func replaysWithTheRefreshedCredential() async throws {
///   let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
///   let transport = MockTransport()
///   transport.setHandler(forPath: "/me") { request in
///     request.headerFields[.authorization] == "Bearer t2"
///       ? .success(MockTransport.Answer(.empty()))
///       : .success(MockTransport.Answer(.empty(status: .unauthorized)))
///   }
///   let client = HTTPClient(
///     authentication: Authentication(provider: tokens, refresher: tokens),
///     baseURL: URL(string: "https://api.example.com")!,
///     transport: transport
///   )
///
///   try await client.executeExpectingNoContent(Request(path: "/me"))
///
///   #expect(tokens.refreshes == 1)
///   #expect(tokens.currentToken() == "t2")
/// }
/// ```
///
/// Pass it as the provider alone to test what a client attaches, and seed
/// ``init(refreshLifetime:refreshOutcomes:timeUntilExpiry:token:)`` with a `timeUntilExpiry` to put
/// ``/HTTPCore/Authentication/refreshThreshold`` under test: a lifetime at or below the threshold is
/// what makes the client refresh before it sends.
///
/// ## Seeding a Refresh
///
/// ``refresh()`` takes the next outcome from the seeded queue. A success installs its token together
/// with the seeded refresh lifetime; a failure throws the ``/HTTPCore/TransportError`` it carries and
/// leaves the credential exactly as it was, which is the contract ``/HTTPCore/TokenRefresher``
/// states. Either outcome is counted in ``refreshes``, so a test reads the count as refreshes asked
/// for rather than refreshes that succeeded.
///
/// A refresh with nothing left in the queue throws
/// ``RecordingTokenProviderFailure/noSeededOutcome``, so a test that seeded too little fails as a
/// test instead of installing a credential nobody wrote.
///
/// ## Isolation
///
/// One `Mutex` guards the credential, the queue, and the count, and a refresh takes its outcome and
/// counts itself in the same critical section, so concurrent refreshes consume each seeded outcome
/// exactly once. Installing the token a success carries is a second critical section, so two
/// concurrent refreshes may install their credentials in an order other than the one they took their
/// outcomes in. The source is not an `actor`, because ``currentToken()`` is a synchronous
/// requirement the client reads on the way into every attempt.
public final class RecordingTokenProvider: TokenProvider, TokenRefresher, Sendable {
  private struct State {
    var outcomes: [Result<String, TransportError>]
    var refreshes = 0
    var timeUntilExpiry: Duration?
    var token: String?
  }

  private let refreshLifetime: Duration?
  private let state: Mutex<State>

  /// Creates a credential source holding the token given, with the refreshes it is to answer with
  /// already seeded.
  ///
  /// - Parameters:
  ///   - refreshLifetime: The remaining lifetime a successful ``refresh()`` installs alongside its
  ///     token; `nil` by default, which reports an unknown lifetime and so opts the refreshed
  ///     credential out of proactive refresh.
  ///   - refreshOutcomes: What each ``refresh()`` answers with, in call order; empty by default.
  ///   - timeUntilExpiry: The remaining lifetime reported until a refresh or an
  ///     ``install(timeUntilExpiry:token:)`` replaces it; `nil` by default, which reports an
  ///     unknown lifetime.
  ///   - token: The credential to hand out; `nil` by default, which is an unauthenticated source.
  public init(
    refreshLifetime: Duration? = nil,
    refreshOutcomes: [Result<String, TransportError>] = [],
    timeUntilExpiry: Duration? = nil,
    token: String? = nil
  ) {
    self.refreshLifetime = refreshLifetime
    state = Mutex(State(outcomes: refreshOutcomes, timeUntilExpiry: timeUntilExpiry, token: token))
  }

  /// How many refreshes have been asked of this source, whether they succeeded or threw.
  public var refreshes: Int {
    state.withLock { $0.refreshes }
  }

  /// The remaining lifetime this source reports, as it was seeded or last installed.
  public var timeUntilExpiry: Duration? {
    state.withLock { $0.timeUntilExpiry }
  }

  /// Returns the credential held right now, or `nil` when there is none.
  ///
  /// - Returns: The current credential, without a scheme prefix.
  public func currentToken() -> String? {
    state.withLock { $0.token }
  }

  /// Replaces the credential and the remaining lifetime reported with it.
  ///
  /// Call it to stand in for a refresh that happened elsewhere, such as another caller's completing
  /// while the request under test was in flight.
  ///
  /// - Parameters:
  ///   - timeUntilExpiry: The remaining lifetime to report from now on; `nil` by default, which
  ///     reports an unknown lifetime.
  ///   - token: The credential to hand out from now on.
  public func install(timeUntilExpiry: Duration? = nil, token: String) {
    state.withLock {
      $0.timeUntilExpiry = timeUntilExpiry
      $0.token = token
    }
  }

  /// Answers with the next seeded outcome, installing its token when it is a success.
  ///
  /// - Throws: The ``/HTTPCore/TransportError`` the outcome carries, leaving the credential
  ///   untouched, or one carrying ``RecordingTokenProviderFailure/noSeededOutcome`` when the queue
  ///   is empty.
  public func refresh() async throws(TransportError) {
    let next = state.withLock { state -> Result<String, TransportError>? in
      state.refreshes += 1
      return state.outcomes.isEmpty ? nil : state.outcomes.removeFirst()
    }
    guard let next else {
      throw .transport(kind: .other, underlying: RecordingTokenProviderFailure.noSeededOutcome)
    }
    install(timeUntilExpiry: refreshLifetime, token: try next.get())
  }
}
