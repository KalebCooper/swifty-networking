import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A client over `RecordingClock`, defaulted apart from the arguments given.
private func makeClient<T: Transport>(
  authentication: Authentication? = nil,
  baseURL: URL = URL.fixture("https://api.example.com"),
  clock: RecordingClock = RecordingClock(),
  observer: (any TransportObserver)? = nil,
  redirectPolicy: RedirectPolicy = .follow,
  transport: T
) -> HTTPClient {
  HTTPClient(
    authentication: authentication,
    baseURL: baseURL,
    clock: clock,
    observer: observer,
    redirectPolicy: redirectPolicy,
    transport: transport
  )
}

/// A credential the client attaches to every request that requires auth.
private let bearer = Authentication(provider: RecordingTokenProvider(token: "t1"))

/// A request whose path and query an absolute destination must leave out.
private let request = Request(path: "/ignored", query: [QueryItem(name: "ignored", value: "1")])

@Suite(
  "HTTPClient absolute destinations and the credential",
  .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientAbsoluteDestinationTests {
  /// RFC 6454: scheme and host compare without regard to case, a port left unwritten is the
  /// scheme's default, userinfo is no part of the origin, and `http` on its own default port is
  /// still another scheme. A bracketed IPv6 host is a host of its own, colons and all.
  @Test(
    "an absolute target carries the credential exactly when its origin is the base's",
    arguments: [
      ("https://api.example.com/items?page=2", true),
      ("HTTPS://API.EXAMPLE.COM/items", true),
      ("https://api.example.com:443/items", true),
      ("https://user@api.example.com/items", true),
      ("https://api.example.com:8443/items", false),
      ("http://api.example.com/items", false),
      ("http://api.example.com:80/items", false),
      ("https://cdn.example.com/items", false),
      ("https://api.example.com.evil/items", false),
      ("https://[2001:db8::1]/items", false),
      ("https://[2001:db8::1]:443/items", false),
    ] as [(String, Bool)]
  )
  func anAbsoluteTargetCarriesTheCredentialOnlyOnTheBasesOrigin(target: String, kept: Bool)
    async throws
  {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(authentication: bearer, transport: transport)

    _ = try await client.perform(request, to: .absolute(target))

    #expect(authorizations(of: transport) == [kept ? "Bearer t1" : nil])
  }

  @Test("an absolute target is sent as written, and the request's path and query take no part")
  func anAbsoluteTargetIsSentAsWritten() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)
    var request = request
    request.headers[.accept] = "application/json"
    request.method = .post

    let delivery = try await client.perform(
      request, to: .absolute("https://cdn.example.com:8443/items?page=2&size=10"))

    let sent = try #require(transport.last?.request)
    #expect(sent.scheme == "https")
    #expect(sent.authority == "cdn.example.com:8443")
    #expect(sent.path == "/items?page=2&size=10")
    #expect(sent.method == .post)
    #expect(sent.headerFields[.accept] == "application/json")
    #expect(delivery.url == "https://cdn.example.com:8443/items?page=2&size=10")
    #expect(delivery.answer.status == .noContent)
  }

  @Test("an absolute target naming only an authority asks for its root")
  func anAuthorityOnlyTargetAsksForItsRoot() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)

    let delivery = try await client.perform(request, to: .absolute("https://api.example.com"))

    #expect(paths(of: transport) == ["/"])
    #expect(delivery.url == "https://api.example.com/")
  }

  @Test(
    "an absolute target naming no scheme or no authority throws badURL, and nothing is sent",
    arguments: ["/items?page=2", "//api.example.com/items", "https:///items", "https:items", ""]
  )
  func anIncompleteTargetThrowsBadURL(target: String) async {
    let observer = RecordingObserver()
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(authentication: bearer, observer: observer, transport: transport)

    let error = await failure { try await client.perform(request, to: .absolute(target)) }

    #expect(isBadURL(error))
    #expect(transport.requests.isEmpty)
    #expect(observer.events.isEmpty)
  }

  @Test("a base naming no host sends a joined request with the credential and an absolute without")
  func aHostlessBaseKeepsTheJoinedFirstHopCredential() async throws {
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])
    let client = makeClient(
      authentication: bearer, baseURL: URL.fixture("https://:8080"), transport: transport)

    _ = try await client.perform(Request(path: "/me"))
    _ = try await client.perform(request, to: .absolute("https://:8080/me"))

    #expect(paths(of: transport) == ["/me", "/me"])
    #expect(authorizations(of: transport) == ["Bearer t1", nil])
  }

  @Test("under a base naming no host, a relative redirect hop withholds the caller's Authorization")
  func aHostlessBaseWithholdsCallerAuthorizationOnARelativeHop() async throws {
    let trace = try #require(HTTPField.Name("X-Trace"))
    let transport = MockTransport(results: [
      .success(redirect(302, to: "/b")),
      .success(.empty()),
    ])
    let client = makeClient(baseURL: URL.fixture("https://:8080"), transport: transport)

    _ = try await client.perform(
      Request(headers: [.authorization: "Basic abc", trace: "abc"], path: "/a"))

    #expect(paths(of: transport) == ["/a", "/b"])
    #expect(authorizations(of: transport) == ["Basic abc", nil])
    #expect(transport.requests.map { $0.request.headerFields[trace] } == ["abc", "abc"])
  }
}

@Suite(
  "HTTPClient absolute destinations and the refresh",
  .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientAbsoluteRefreshTests {
  @Test(
    "a 401 from a cross-origin absolute send is the failure: no refresh, one send, no credential")
  func aCrossOrigin401EarnsNoRefresh() async {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport(results: [.success(.empty(status: .unauthorized))])
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens), transport: transport)

    let error = await failure {
      try await client.perform(request, to: .absolute("https://cdn.example.com/items"))
    }

    #expect(statusCode(error) == 401)
    #expect(tokens.refreshes == 0)
    #expect(authorizations(of: transport) == [nil])
  }

  @Test(
    "under a base naming no host, a 401 on a relative hop refreshes once and the replay's first send carries the new token"
  )
  func aHostlessBase401OnARelativeHopRefreshes() async throws {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport(results: [
      .success(redirect(302, to: "/b")),
      .success(.empty(status: .unauthorized)),
      .success(redirect(302, to: "/b")),
      .success(.empty()),
    ])
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens),
      baseURL: URL.fixture("https://:8080"), transport: transport)

    let delivery = try await client.perform(Request(path: "/a"))

    #expect(delivery.answer.status == .noContent)
    #expect(tokens.refreshes == 1)
    #expect(paths(of: transport) == ["/a", "/b", "/a", "/b"])
    #expect(authorizations(of: transport) == ["Bearer t1", nil, "Bearer t2", nil])
  }

  @Test("an expiring credential is not refreshed ahead of a cross-origin absolute send")
  func aCrossOriginSendSkipsTheProactiveRefresh() async throws {
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.success("t2")], timeUntilExpiry: .zero, token: "t1")
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      authentication: Authentication(
        provider: tokens, refresher: tokens, refreshThreshold: .seconds(30)),
      transport: transport)

    _ = try await client.perform(request, to: .absolute("https://cdn.example.com/items"))

    #expect(tokens.refreshes == 0)
    #expect(authorizations(of: transport) == [nil])
  }

  @Test("a 401 from a hop that landed on the base's origin still earns its refresh and replay")
  func a401OnTheBasesOriginStillRefreshes() async throws {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: "/a") { _ in
      .success(MockTransport.Answer(redirect(302, to: "https://api.example.com/b")))
    }
    transport.setHandler(forPath: "/b") { request in
      guard request.headerFields[.authorization] == "Bearer t2" else {
        return .success(MockTransport.Answer(.empty(status: .unauthorized)))
      }
      return .success(MockTransport.Answer(.empty()))
    }
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens), transport: transport)

    _ = try await client.perform(request, to: .absolute("https://cdn.example.com/a"))

    #expect(tokens.refreshes == 1)
    #expect(paths(of: transport) == ["/a", "/b", "/a", "/b"])
    #expect(authorizations(of: transport) == [nil, "Bearer t1", nil, "Bearer t2"])
  }
}

@Suite("HTTPClient redirects after an absolute send", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientAbsoluteRedirectTests {
  /// The credential belongs to the base's origin, so a hop earns it by landing there, wherever
  /// the chain started; a chain that stays on another host never sees it.
  @Test(
    "a hop after an absolute send carries the credential exactly when its origin is the base's",
    arguments: [
      ("https://cdn.example.com/a", "https://cdn.example.com/b", [nil, nil]),
      ("https://cdn.example.com/a", "/b", [nil, nil]),
      ("https://cdn.example.com/a", "https://api.example.com/b", [nil, "Bearer t1"]),
      ("https://api.example.com/a", "https://cdn.example.com/b", ["Bearer t1", nil]),
      ("https://api.example.com/a", "/b", ["Bearer t1", "Bearer t1"]),
    ] as [(String, String, [String?])]
  )
  func aHopAfterAnAbsoluteSendFollowsTheCredentialRule(
    target: String, location: String, expected: [String?]
  ) async throws {
    let transport = MockTransport(results: [
      .success(redirect(302, to: location)),
      .success(.empty()),
    ])
    let client = makeClient(authentication: bearer, transport: transport)

    _ = try await client.perform(request, to: .absolute(target))

    #expect(authorizations(of: transport) == expected)
  }

  /// RFC 3986 5.2: `../next` against `/items/list` merges to `/items/next`, then the dot segment
  /// climbs one level, leaving `/next`.
  @Test("a relative Location after an absolute send resolves against the absolute target")
  func aRelativeLocationResolvesAgainstTheAbsoluteTarget() async throws {
    let transport = MockTransport(results: [
      .success(redirect(302, to: "../next?page=2")),
      .success(.empty()),
    ])
    let client = makeClient(transport: transport)

    let delivery = try await client.perform(
      request, to: .absolute("https://cdn.example.com/items/list?page=1"))

    #expect(paths(of: transport) == ["/items/list?page=1", "/next?page=2"])
    #expect(transport.last?.request.authority == "cdn.example.com")
    #expect(delivery.url == "https://cdn.example.com/next?page=2")
  }

  @Test(
    "sameOrigin holds the chain to the origin the request was sent to, not to the base's",
    arguments: [("https://cdn.example.com/b", true), ("https://api.example.com/b", false)]
  )
  func sameOriginReadsTheOriginTheRequestWasSentTo(location: String, followed: Bool) async {
    let transport = MockTransport(results: [
      .success(redirect(302, to: location)),
      .success(.empty()),
    ])
    let client = makeClient(redirectPolicy: .sameOrigin, transport: transport)

    let error = await failure {
      try await client.perform(request, to: .absolute("https://cdn.example.com/a"))
    }

    #expect(statusCode(error) == (followed ? nil : 302))
    #expect(transport.requests.count == (followed ? 2 : 1))
  }
}

@Suite("HTTPClient delivery URL", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientDeliveryURLTests {
  @Test("a base-joined request delivers the URL it was sent to")
  func aJoinedRequestDeliversItsOwnURL() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)

    let delivery = try await client.perform(
      Request(path: "/items", query: [QueryItem(name: "page", value: "1")]))

    #expect(delivery.url == "https://api.example.com/items?page=1")
  }

  @Test("a redirect chain delivers the URL of the hop that answered")
  func aRedirectChainDeliversTheLastHopsURL() async throws {
    let transport = MockTransport(results: [
      .success(redirect(302, to: "https://api.example.com/new?p=2")),
      .success(redirect(302, to: "final")),
      .success(.empty()),
    ])
    let client = makeClient(transport: transport)

    let delivery = try await client.perform(Request(path: "/old"))

    #expect(paths(of: transport) == ["/old", "/new?p=2", "/final"])
    #expect(delivery.url == "https://api.example.com/final")
  }

  @Test("a coalesced flight delivers the redirected URL to every caller, from one chain")
  func aCoalescedFlightDeliversTheRedirectedURL() async throws {
    let clock = RecordingClock()
    let ok = Response.ok(json: Fixtures.jsonObject(["name": "Ada"]))
    let mock = MockTransport(results: [
      .success(redirect(302, to: "https://api.example.com/people/1")),
      .success(ok),
    ])
    let client = makeClient(clock: clock, transport: HoldingTransport(clock: clock, inner: mock))
    let request = Request(options: RequestOptions(coalescingKey: "person-1"), path: "/old")

    // `Task.immediate` runs each caller to its first suspension in turn, so both have registered
    // under the key before the flight's first send is released.
    let calls = (0..<2).map { _ in Task.immediate { try await client.perform(request) } }
    await answerWaits(2, of: clock)

    for call in calls {
      let delivery = try await call.value
      #expect(delivery.answer == ok)
      #expect(delivery.url == "https://api.example.com/people/1")
    }
    #expect(paths(of: mock) == ["/old", "/people/1"])
  }
}
