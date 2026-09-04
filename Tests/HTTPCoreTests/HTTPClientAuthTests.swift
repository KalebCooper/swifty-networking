import HTTPCore
import HTTPTesting
import HTTPTypes
import Synchronization
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A refresher that holds every caller on a latch before handing the refresh to the credential
/// source the client reads, so a test can keep one refresh open while the callers behind it arrive.
private final class HoldingRefresher: TokenRefresher, Sendable {
  private let arrivals: Int
  private let cancellation = Mutex(false)
  private let latch: Latch
  private let tokens: RecordingTokenProvider

  init(arrivals: Int, latch: Latch, tokens: RecordingTokenProvider) {
    self.arrivals = arrivals
    self.latch = latch
    self.tokens = tokens
  }

  /// Whether any refresh began on a cancelled task.
  var sawCancellation: Bool { cancellation.withLock { $0 } }

  func refresh() async throws(TransportError) {
    cancellation.withLock { $0 = $0 || Task.isCancelled }
    await latch.wait(forCount: arrivals)
    try await tokens.refresh()
  }
}

/// A client over `MockTransport` and `RecordingClock`, defaulted apart from the auth arguments.
private func makeClient(
  authentication: Authentication? = nil,
  defaultHeaders: HTTPFields = [:],
  transport: MockTransport
) -> HTTPClient {
  HTTPClient(
    authentication: authentication,
    baseURL: URL.fixture("https://api.example.com"),
    clock: RecordingClock(),
    defaultHeaders: defaultHeaders,
    transport: transport
  )
}

/// A handler that accepts exactly the credentials given and answers `401` for every other.
private func accepting(_ tokens: String...)
  -> @Sendable (HTTPRequest) -> Result<MockTransport.Answer, TransportError>
{
  let accepted = Set(tokens.map { "Bearer \($0)" })
  return { request in
    guard let credential = request.headerFields[.authorization], accepted.contains(credential)
    else { return .success(MockTransport.Answer(.empty(status: .unauthorized))) }
    return .success(MockTransport.Answer(.empty(status: .ok)))
  }
}

/// The `Authorization` values the transport saw, in send order; `nil` where a request carried none.
private func authorizations(of transport: MockTransport) -> [String?] {
  transport.requests.map { $0.request.headerFields[.authorization] }
}

private let path = "/me"
private let anonymous = Request(options: RequestOptions(requiresAuth: false), path: path)

@Suite("HTTPClient credential attachment", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientAttachTests {
  @Test("a request that requires auth carries the provider's token as a Bearer credential")
  func attachesBearer() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      authentication: Authentication(provider: RecordingTokenProvider(token: "t1")),
      transport: transport)

    try await client.executeExpectingNoContent(Request(path: path))

    #expect(authorizations(of: transport) == ["Bearer t1"])
  }

  @Test("a request that does not require auth never reads the provider and never refreshes a 401")
  func anonymousSkipsAuth() async throws {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: path, handler: accepting("t2"))
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens), transport: transport)

    let error = await failure { try await client.executeExpectingNoContent(anonymous) }

    #expect(error?.statusCode == 401)
    #expect(authorizations(of: transport) == [nil])
    #expect(tokens.refreshes == 0)
  }

  @Test("a provider holding no token sends the request unauthenticated, without failing it")
  func nilTokenSendsUnauthenticated() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      authentication: Authentication(provider: RecordingTokenProvider(token: nil)),
      transport: transport)

    try await client.executeExpectingNoContent(Request(path: path))

    #expect(authorizations(of: transport) == [nil])
  }

  @Test(
    "the provider's token replaces an Authorization field the caller set; a nil token leaves it")
  func providerTokenWinsOverCallerField() async throws {
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])
    let defaults: HTTPFields = [.authorization: "Basic abc"]

    try await makeClient(
      authentication: Authentication(provider: RecordingTokenProvider(token: "t1")),
      defaultHeaders: defaults,
      transport: transport
    )
    .executeExpectingNoContent(Request(path: path))
    try await makeClient(
      authentication: Authentication(provider: RecordingTokenProvider(token: nil)),
      defaultHeaders: defaults,
      transport: transport
    )
    .executeExpectingNoContent(Request(path: path))

    #expect(authorizations(of: transport) == ["Bearer t1", "Basic abc"])
  }

  @Test("the basic scheme renders the credential into the Authorization field, prefixed Basic")
  func attachesBasic() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      authentication: Authentication(
        provider: RecordingTokenProvider(token: "dXNlcjpwYXNz"), scheme: .basic),
      transport: transport)

    try await client.executeExpectingNoContent(Request(path: path))

    #expect(authorizations(of: transport) == ["Basic dXNlcjpwYXNz"])
  }

  @Test("a credential from basicCredential(password:username:) is sent exactly as it was built")
  func attachesABuiltBasicCredential() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let credential = Authentication.basicCredential(password: "open sesame", username: "Aladdin")
    let client = makeClient(
      authentication: Authentication(
        provider: RecordingTokenProvider(token: credential), scheme: .basic),
      transport: transport)

    try await client.executeExpectingNoContent(Request(path: path))

    #expect(authorizations(of: transport) == ["Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ=="])
  }

  @Test("the provider's token replaces a custom field the caller set; a nil token leaves it")
  func providerTokenWinsOverACallerSetCustomField() async throws {
    let apiKey = try #require(HTTPField.Name("X-API-Key"))
    let defaults: HTTPFields = [apiKey: "caller"]
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])

    try await makeClient(
      authentication: Authentication(
        provider: RecordingTokenProvider(token: "k1"), scheme: .field(apiKey)),
      defaultHeaders: defaults,
      transport: transport
    )
    .executeExpectingNoContent(Request(path: path))
    try await makeClient(
      authentication: Authentication(
        provider: RecordingTokenProvider(token: nil), scheme: .field(apiKey)),
      defaultHeaders: defaults,
      transport: transport
    )
    .executeExpectingNoContent(Request(path: path))

    #expect(transport.requests.map { $0.request.headerFields[apiKey] } == ["k1", "caller"])
  }

  @Test("a scheme naming a field renders the credential into that field, unprefixed and alone")
  func attachesIntoTheFieldTheSchemeNames() async throws {
    let apiKey = try #require(HTTPField.Name("X-API-Key"))
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      authentication: Authentication(
        provider: RecordingTokenProvider(token: "k1"), scheme: .field(apiKey)),
      transport: transport)

    try await client.executeExpectingNoContent(Request(path: path))

    #expect(transport.requests.map { $0.request.headerFields[apiKey] } == ["k1"])
    #expect(authorizations(of: transport) == [nil])
  }
}

@Suite("HTTPClient proactive refresh", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientProactiveRefreshTests {
  @Test(
    "a refresh precedes the send exactly when the remaining lifetime is at or below the threshold",
    arguments: [
      (Duration.seconds(30), Duration.seconds(30), true),
      (.seconds(30), .seconds(29), true),
      (.seconds(30), .seconds(-5), true),
      (.seconds(30), .seconds(31), false),
      (.seconds(30), nil, false),
      (nil, .seconds(5), false),
      (nil, nil, false),
    ]
  )
  func thresholdMatrix(threshold: Duration?, remaining: Duration?, refreshes: Bool) async throws {
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.success("t2")], timeUntilExpiry: remaining, token: "t1")
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      authentication: Authentication(
        provider: tokens, refresher: tokens, refreshThreshold: threshold),
      transport: transport
    )

    try await client.executeExpectingNoContent(Request(path: path))

    #expect(tokens.refreshes == (refreshes ? 1 : 0))
    #expect(authorizations(of: transport) == [refreshes ? "Bearer t2" : "Bearer t1"])
  }

  @Test("no refresher, or a request that does not require auth, means no proactive refresh")
  func needsRefresherAndAuth() async throws {
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.success("t2")], timeUntilExpiry: .seconds(1), token: "t1")
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])

    try await makeClient(
      authentication: Authentication(provider: tokens, refreshThreshold: .seconds(30)),
      transport: transport
    )
    .executeExpectingNoContent(Request(path: path))
    try await makeClient(
      authentication: Authentication(
        provider: tokens, refresher: tokens, refreshThreshold: .seconds(30)),
      transport: transport
    )
    .executeExpectingNoContent(anonymous)

    #expect(tokens.refreshes == 0)
    #expect(authorizations(of: transport) == ["Bearer t1", nil])
  }

  @Test("a proactive refresh that fails fails the request with the refresher's error, nothing sent")
  func failurePropagatesBeforeSending() async {
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.failure(.transport(kind: .connectivity, underlying: nil))],
      timeUntilExpiry: .zero,
      token: "t1"
    )
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      authentication: Authentication(
        provider: tokens, refresher: tokens, refreshThreshold: .seconds(30)),
      transport: transport
    )

    let error = await failure { try await client.executeExpectingNoContent(Request(path: path)) }

    guard case .transport(kind: .connectivity, underlying: nil)? = error else {
      Issue.record(
        "expected the refresher's connectivity failure, got \(String(describing: error))")
      return
    }
    #expect(transport.requests.isEmpty)
    #expect(tokens.currentToken() == "t1")
  }

  @Test("a 401 after a proactive refresh still earns its one reactive refresh and replay")
  func reactiveFollowsProactive() async throws {
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.success("t2"), .success("t3")], timeUntilExpiry: .zero, token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: path, handler: accepting("t3"))
    let client = makeClient(
      authentication: Authentication(
        provider: tokens, refresher: tokens, refreshThreshold: .seconds(30)),
      transport: transport
    )

    try await client.executeExpectingNoContent(Request(path: path))

    #expect(tokens.refreshes == 2)
    #expect(authorizations(of: transport) == ["Bearer t2", "Bearer t3"])
  }

  @Test("the default refresh lifetime opts the refreshed credential out of a second refresh")
  func defaultRefreshLifetimeOptsOutOfASecondRefresh() async throws {
    // Seeded without a refreshLifetime, so the refresh installs an unknown lifetime, and with one
    // outcome only, so a second proactive refresh would fail the second send rather than pass it.
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.success("t2")], timeUntilExpiry: .zero, token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: path, handler: accepting("t2"))
    let client = makeClient(
      authentication: Authentication(
        provider: tokens, refresher: tokens, refreshThreshold: .seconds(30)),
      transport: transport
    )

    try await client.executeExpectingNoContent(Request(path: path))
    try await client.executeExpectingNoContent(Request(path: path))

    #expect(tokens.refreshes == 1)
    #expect(tokens.timeUntilExpiry == nil)
    #expect(authorizations(of: transport) == ["Bearer t2", "Bearer t2"])
  }
}

@Suite("HTTPClient 401 replay", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientReplayTests {
  @Test("a 401 refreshes once and replays with the new credential, on every entry point")
  func refreshesAndReplays() async throws {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: path) { request in
      guard request.headerFields[.authorization] == "Bearer t2" else {
        return .success(MockTransport.Answer(.empty(status: .unauthorized)))
      }
      return .success(MockTransport.Answer(.ok(json: Data(#"{"id":7}"#.utf8))))
    }
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens), transport: transport)

    struct Me: Decodable { let id: Int }
    let me: Me = try await client.execute(Request(path: path))
    let raw = try await client.execute(Request(path: path))
    try await client.executeExpectingNoContent(Request(path: path))
    let headered: DecodedResponse<Me> = try await client.execute(Request(path: path))

    #expect(me.id == 7)
    #expect(raw.status == .ok)
    #expect(headered.value.id == 7)
    #expect(tokens.refreshes == 1)
    #expect(
      authorizations(of: transport) == [
        "Bearer t1", "Bearer t2", "Bearer t2", "Bearer t2", "Bearer t2",
      ])
  }

  @Test("a 401 under a scheme other than bearer refreshes once and replays in the same field")
  func refreshesAndReplaysUnderAnotherScheme() async throws {
    let apiKey = try #require(HTTPField.Name("X-API-Key"))
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("k2")], token: "k1")
    let transport = MockTransport()
    transport.setHandler(forPath: path) { request in
      guard request.headerFields[apiKey] == "k2" else {
        return .success(MockTransport.Answer(.empty(status: .unauthorized)))
      }
      return .success(MockTransport.Answer(.empty()))
    }
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens, scheme: .field(apiKey)),
      transport: transport)

    try await client.executeExpectingNoContent(Request(path: path))

    #expect(tokens.refreshes == 1)
    #expect(transport.requests.map { $0.request.headerFields[apiKey] } == ["k1", "k2"])
    #expect(authorizations(of: transport) == [nil, nil])
  }

  @Test("a second 401 is the status failure, after exactly one refresh and one replay")
  func secondUnauthorizedPropagates() async {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: path, handler: accepting("never"))
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens), transport: transport)

    let error = await failure { try await client.executeExpectingNoContent(Request(path: path)) }

    #expect(error?.statusCode == 401)
    #expect(tokens.refreshes == 1)
    #expect(authorizations(of: transport) == ["Bearer t1", "Bearer t2"])
  }

  @Test("with replay turned off, or no refresher, a 401 propagates untouched")
  func replayOffOrNoRefresherPropagates() async {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: path, handler: accepting("t2"))
    let clients = [
      makeClient(
        authentication: Authentication(provider: tokens, refresher: tokens, replayOn401: false),
        transport: transport
      ),
      makeClient(authentication: Authentication(provider: tokens), transport: transport),
    ]

    for client in clients {
      let error = await failure { try await client.executeExpectingNoContent(Request(path: path)) }
      #expect(error?.statusCode == 401)
    }

    #expect(tokens.refreshes == 0)
    #expect(authorizations(of: transport) == ["Bearer t1", "Bearer t1"])
  }

  @Test("a failed refresh propagates the refresher's error, discards the 401, and replays nothing")
  func refreshFailurePropagates() async {
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.failure(.transport(kind: .timedOut, underlying: nil))], token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: path, handler: accepting("t2"))
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens), transport: transport)

    let error = await failure { try await client.executeExpectingNoContent(Request(path: path)) }

    #expect(error?.isTimeout == true)
    #expect(tokens.refreshes == 1)
    #expect(tokens.currentToken() == "t1")
    #expect(authorizations(of: transport) == ["Bearer t1"])
  }

  @Test("a 401 for a token the provider has since replaced replays without refreshing")
  func replacedTokenReplaysWithoutRefresh() async throws {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("never")], token: "t1")
    let transport = MockTransport()
    // The server refuses `t1` and installs `t2` as it does, standing in for another caller's refresh
    // completing while this request was in flight.
    transport.setHandler(forPath: path) { request in
      guard request.headerFields[.authorization] == "Bearer t2" else {
        tokens.install(token: "t2")
        return .success(MockTransport.Answer(.empty(status: .unauthorized)))
      }
      return .success(MockTransport.Answer(.empty()))
    }
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens), transport: transport)

    try await client.executeExpectingNoContent(Request(path: path))

    #expect(tokens.refreshes == 0)
    #expect(authorizations(of: transport) == ["Bearer t1", "Bearer t2"])
  }
}

@Suite("HTTPClient single-flight refresh", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientSingleFlightTests {
  @Test("eight concurrent 401s share exactly one refresh and all replay successfully")
  func eightCallersOneRefresh() async throws {
    let callers = 8
    let latch = Latch()
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let refresher = HoldingRefresher(arrivals: callers, latch: latch, tokens: tokens)
    let transport = MockTransport()
    let accept = accepting("t2")
    transport.setHandler(forPath: path) { request in
      latch.arrive()
      return accept(request)
    }
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: refresher), transport: transport)
    let copy = client

    let statuses = try await withThrowingTaskGroup(of: HTTPResponse.Status.self) { group in
      for index in 0..<callers {
        group.addTask {
          try await (index.isMultiple(of: 2) ? client : copy).execute(Request(path: path)).status
        }
      }
      return try await group.reduce(into: [HTTPResponse.Status]()) { $0.append($1) }
    }

    #expect(statuses == Array(repeating: .ok, count: callers))
    #expect(tokens.refreshes == 1)
    #expect(refresher.sawCancellation == false)
    let sent = authorizations(of: transport)
    #expect(sent.count == callers * 2)
    #expect(sent.prefix(callers).allSatisfy { $0 == "Bearer t1" })
    #expect(sent.suffix(callers).allSatisfy { $0 == "Bearer t2" })
  }

  @Test("cancelling a caller, leader or joiner, neither cancels nor abandons the shared refresh")
  func cancelledCallerLeavesRefreshRunning() async throws {
    let latch = Latch()
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let refresher = HoldingRefresher(arrivals: 3, latch: latch, tokens: tokens)
    let transport = MockTransport()
    let accept = accepting("t2")
    transport.setHandler(forPath: path) { request in
      latch.arrive()
      return accept(request)
    }
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: refresher), transport: transport)

    let first = Task { try await client.execute(Request(path: path)).status }
    let second = Task { try await client.execute(Request(path: path)).status }
    await latch.wait(forCount: 2)
    second.cancel()
    latch.arrive()

    // The cancelled caller leaves with `cancelled`: it reads its response body through a
    // `StreamedBody`, which refuses a cancelled task, as a live transport does. What the shared
    // refresh does in its absence is the claim under test.
    #expect(try await first.value == .ok)
    #expect(await failure { try await second.value }?.description == "cancelled")
    #expect(tokens.refreshes == 1)
    #expect(refresher.sawCancellation == false)
    #expect(tokens.currentToken() == "t2")
    #expect(authorizations(of: transport) == ["Bearer t1", "Bearer t1", "Bearer t2", "Bearer t2"])
  }
}

@Suite("HTTPClient derived credentials", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientDerivedCredentialTests {
  @Test("an authentication set on a copy is sent by the copy and by nobody else")
  func aDerivedAuthenticationStaysOnTheCopy() async throws {
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])
    let client = makeClient(
      authentication: Authentication(provider: RecordingTokenProvider(token: "o1")),
      transport: transport)
    var derived = client
    derived.authentication = Authentication(provider: RecordingTokenProvider(token: "d1"))

    try await derived.executeExpectingNoContent(Request(path: path))
    try await client.executeExpectingNoContent(Request(path: path))

    #expect(authorizations(of: transport) == ["Bearer d1", "Bearer o1"])
  }

  @Test("a copy that meets a 401 refreshes its own provider through its own refresher")
  func aDerivedCopyRefreshesItsOwnProvider() async throws {
    let originalTokens = RecordingTokenProvider(refreshOutcomes: [.success("o2")], token: "o1")
    let derivedTokens = RecordingTokenProvider(refreshOutcomes: [.success("d2")], token: "d1")
    let transport = MockTransport()
    transport.setHandler(forPath: path, handler: accepting("d2"))
    let client = makeClient(
      authentication: Authentication(provider: originalTokens, refresher: originalTokens),
      transport: transport)
    var derived = client
    derived.authentication = Authentication(provider: derivedTokens, refresher: derivedTokens)

    try await derived.executeExpectingNoContent(Request(path: path))

    #expect(authorizations(of: transport) == ["Bearer d1", "Bearer d2"])
    #expect(derivedTokens.refreshes == 1)
    #expect(originalTokens.refreshes == 0)
    #expect(originalTokens.currentToken() == "o1")
  }

  @Test("a new authentication on a copy refreshes on its own gate")
  func aNewAuthenticationRefreshesOnItsOwnGate() async throws {
    let latch = Latch()
    let originalTokens = RecordingTokenProvider(refreshOutcomes: [.success("o2")], token: "o1")
    let originalRefresher = HoldingRefresher(arrivals: 2, latch: latch, tokens: originalTokens)
    let derivedTokens = RecordingTokenProvider(refreshOutcomes: [.success("d2")], token: "d1")
    let derivedRefresher = HoldingRefresher(arrivals: 2, latch: latch, tokens: derivedTokens)
    let transport = MockTransport()
    let accept = accepting("d2", "o2")
    transport.setHandler(forPath: path) { request in
      latch.arrive()
      return accept(request)
    }
    let client = makeClient(
      authentication: Authentication(provider: originalTokens, refresher: originalRefresher),
      transport: transport)
    var derived = client
    derived.authentication = Authentication(provider: derivedTokens, refresher: derivedRefresher)
    let copy = derived

    // Each refresh is held until both first attempts have reached the transport, so neither can
    // finish before the other has begun. Over one shared gate the second arrival would join the
    // first's refresh, re-read its own untouched credential, and meet the `401` again.
    let statuses = try await withThrowingTaskGroup(of: HTTPResponse.Status.self) { group in
      group.addTask { try await client.execute(Request(path: path)).status }
      group.addTask { try await copy.execute(Request(path: path)).status }
      return try await group.reduce(into: [HTTPResponse.Status]()) { $0.append($1) }
    }

    #expect(statuses == [.ok, .ok])
    #expect(originalTokens.refreshes == 1)
    #expect(derivedTokens.refreshes == 1)
    #expect(originalTokens.currentToken() == "o2")
    #expect(derivedTokens.currentToken() == "d2")
  }

  @Test("changing replayOn401 on a copy keeps sharing the original's refresh")
  func changingReplayOn401OnACopyKeepsTheGate() async throws {
    let latch = Latch()
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.success("o2")], timeUntilExpiry: .zero, token: "o1")
    let refresher = HoldingRefresher(arrivals: 1, latch: latch, tokens: tokens)
    let transport = MockTransport()
    transport.setHandler(forPath: path, handler: accepting("o2"))
    let client = makeClient(
      authentication: Authentication(
        provider: tokens, refresher: refresher, refreshThreshold: .seconds(30)),
      transport: transport)
    var derived = client
    derived.authentication?.replayOn401 = false
    let copy = derived

    // Both callers find the credential expiring and reach the gate before the refresh is released,
    // so whether they share the gate is what the count reads. The release cannot be armed from an
    // observed arrival as the `401` tests arm theirs: a proactive refresh happens before the
    // transport is reached, and the last thing a joiner does before it parks, the credential read,
    // is followed by the gate's own critical section, so a refresh released on that read could land
    // in between and a copy on a gate of its own would skip as a joiner does. `Task.immediate` is
    // the ordering instead: it runs each caller to its first suspension in turn, so the client
    // leads the refresh and parks on it, and the copy is parked in the same gate when the latch
    // opens below, unless it took a gate of its own, in which case it leads a second refresh with
    // nothing seeded to answer it and its call fails.
    let first = Task.immediate { try await client.execute(Request(path: path)).status }
    let second = Task.immediate { try await copy.execute(Request(path: path)).status }
    latch.arrive()

    #expect(try await first.value == .ok)
    #expect(try await second.value == .ok)
    #expect(tokens.refreshes == 1)
    #expect(tokens.currentToken() == "o2")
    #expect(authorizations(of: transport) == ["Bearer o2", "Bearer o2"])
  }

  @Test("a copy taken after an assignment carries the new authentication, not the original's")
  func aCopyTakenAfterAnAssignmentCarriesTheNewAuthentication() async throws {
    let originalTokens = RecordingTokenProvider(refreshOutcomes: [.success("o2")], token: "o1")
    let derivedTokens = RecordingTokenProvider(refreshOutcomes: [.success("d2")], token: "d1")
    let transport = MockTransport()
    transport.setHandler(forPath: path, handler: accepting("d2"))
    let client = makeClient(
      authentication: Authentication(provider: originalTokens, refresher: originalTokens),
      transport: transport)
    var derived = client
    derived.authentication = Authentication(provider: derivedTokens, refresher: derivedTokens)
    let copy = derived

    try await copy.executeExpectingNoContent(Request(path: path))

    #expect(authorizations(of: transport) == ["Bearer d1", "Bearer d2"])
    #expect(derivedTokens.refreshes == 1)
    #expect(originalTokens.refreshes == 0)
  }
}
