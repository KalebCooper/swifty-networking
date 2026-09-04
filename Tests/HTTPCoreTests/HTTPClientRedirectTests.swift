import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A client over `MockTransport` and `RecordingClock`, defaulted apart from the arguments given.
private func makeClient(
  authentication: Authentication? = nil,
  defaultHeaders: HTTPFields = [:],
  observer: (any TransportObserver)? = nil,
  redirectPolicy: RedirectPolicy = .follow,
  transport: MockTransport
) -> HTTPClient {
  HTTPClient(
    authentication: authentication,
    baseURL: URL.fixture("https://api.example.com"),
    clock: RecordingClock(),
    defaultHeaders: defaultHeaders,
    observer: observer,
    redirectPolicy: redirectPolicy,
    transport: transport
  )
}

/// A redirect carrying `location`, with a body a follower must never read.
private func redirect(_ code: Int, to location: String?) -> Response {
  var headers: HTTPFields = [:]
  if let location { headers[.location] = location }
  return Response(
    body: Data("<html>moved</html>".utf8), headers: headers, status: HTTPResponse.Status(code: code)
  )
}

/// The `Location` field a status failure carries, or `nil` for any other failure.
private func location(of error: TransportError?) -> String? {
  guard case .httpStatus(body: _, code: _, headers: let headers)? = error else { return nil }
  return headers[.location]
}

/// The `:path` of every request the transport saw, in send order.
private func paths(of transport: MockTransport) -> [String?] {
  transport.requests.map { $0.request.path }
}

/// The `Authorization` values the transport saw, in send order; `nil` where a request carried none.
private func authorizations(of transport: MockTransport) -> [String?] {
  transport.requests.map { $0.request.headerFields[.authorization] }
}

private let elsewhere = "https://other.example.com/x"

@Suite("HTTPClient redirects", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientRedirectTests {
  @Test("a 302 is followed to its Location and the final response returned")
  func a302IsFollowed() async throws {
    let transport = MockTransport(results: [
      .success(redirect(302, to: "https://api.example.com/new")),
      .success(.ok(json: Data(#"{"id":7}"#.utf8))),
    ])
    let client = makeClient(transport: transport)

    let response: Response = try await client.execute(Request(path: "/old"))

    #expect(response.status == .ok)
    #expect(response.body == Data(#"{"id":7}"#.utf8))
    #expect(paths(of: transport) == ["/old", "/new"])
    #expect(transport.last?.request.authority == "api.example.com")
  }

  @Test("a relative Location is resolved against the request URL")
  func aRelativeLocationIsResolved() async throws {
    let transport = MockTransport(results: [
      .success(redirect(302, to: "../d?x=1")),
      .success(.empty()),
    ])
    let client = makeClient(transport: transport)

    try await client.executeExpectingNoContent(Request(path: "/a/b/c"))

    // RFC 3986 5.4.1: "../d" against "https://api.example.com/a/b/c" is "/a/d".
    #expect(paths(of: transport) == ["/a/b/c", "/a/d?x=1"])
    #expect(transport.last?.request.scheme == "https")
    #expect(transport.last?.request.authority == "api.example.com")
  }

  @Test("a Location naming only an authority is followed to its root")
  func anAuthorityOnlyLocationIsFollowedToItsRoot() async throws {
    let transport = MockTransport(results: [
      .success(redirect(302, to: "https://other.example.com")),
      .success(.empty()),
    ])
    let client = makeClient(transport: transport)

    try await client.executeExpectingNoContent(Request(path: "/things"))

    #expect(paths(of: transport) == ["/things", "/"])
    #expect(transport.last?.request.authority == "other.example.com")
  }

  @Test("a 303 after a POST is followed with GET and no body", arguments: [301, 302, 303])
  func a303AfterAPostBecomesAGet(code: Int) async throws {
    let transport = MockTransport(results: [
      .success(redirect(code, to: "/done")),
      .success(.empty()),
    ])
    let client = makeClient(transport: transport)

    try await client.executeExpectingNoContent(
      Request(body: .json(["name": "x"]), method: .post, path: "/things"))

    let calls = transport.requests
    #expect(calls.count == 2)
    #expect(calls.first?.request.method == .post)
    #expect(calls.first?.request.headerFields[.contentType] == "application/json")
    #expect(calls.last?.request.method == .get)
    #expect(calls.last?.body == TransportBody.none)
    #expect(calls.last?.request.headerFields[.contentType] == nil)
    #expect(calls.last?.request.headerFields[.contentLength] == nil)
  }

  @Test("a HEAD redirected by a 303 stays HEAD")
  func aHeadStaysAHead() async throws {
    let transport = MockTransport(results: [
      .success(redirect(303, to: "/done")),
      .success(.empty()),
    ])
    let client = makeClient(transport: transport)

    try await client.executeExpectingNoContent(Request(method: .head, path: "/things"))

    #expect(transport.requests.map { $0.request.method } == [.head, .head])
  }

  @Test("a 307 after a POST keeps the method and the body", arguments: [307, 308])
  func a307AfterAPostKeepsTheRequest(code: Int) async throws {
    let payload = Data("payload".utf8)
    let transport = MockTransport(results: [
      .success(redirect(code, to: "/done")),
      .success(.empty()),
    ])
    let client = makeClient(transport: transport)

    try await client.executeExpectingNoContent(
      Request(body: .bytes(payload, contentType: "text/plain"), method: .post, path: "/things"))

    let calls = transport.requests
    #expect(calls.count == 2)
    #expect(calls.last?.request.method == .post)
    #expect(calls.last?.body == .bytes(payload))
    #expect(calls.last?.request.headerFields[.contentType] == "text/plain")
    #expect(calls.last?.request.path == "/done")
  }

  @Test("the fields the caller set travel with every hop, and a custom one crosses origins")
  func callerFieldsTravel() async throws {
    let transport = MockTransport(results: [
      .success(redirect(302, to: elsewhere)),
      .success(.empty()),
    ])
    let client = makeClient(
      defaultHeaders: [.authorization: "Basic abc", .accept: "application/json"],
      transport: transport)

    try await client.executeExpectingNoContent(Request(path: "/things"))

    #expect(authorizations(of: transport) == ["Basic abc", "Basic abc"])
    #expect(
      transport.requests.map { $0.request.headerFields[.accept] }
        == ["application/json", "application/json"])
  }
}

@Suite("HTTPClient redirects and the credential", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientRedirectCredentialTests {
  @Test("a cross-origin hop drops the credential under follow")
  func aCrossOriginHopDropsTheCredential() async throws {
    let transport = MockTransport(results: [
      .success(redirect(302, to: elsewhere)),
      .success(.empty()),
    ])
    let client = makeClient(
      authentication: Authentication(provider: RecordingTokenProvider(token: "t1")),
      transport: transport)

    try await client.executeExpectingNoContent(Request(path: "/things"))

    #expect(authorizations(of: transport) == ["Bearer t1", nil])
    #expect(transport.last?.request.authority == "other.example.com")
  }

  @Test("a cross-origin hop drops a credential the scheme rendered into a field of its own")
  func aCrossOriginHopDropsACredentialInAnotherField() async throws {
    let apiKey = try #require(HTTPField.Name("X-API-Key"))
    let transport = MockTransport(results: [
      .success(redirect(302, to: elsewhere)),
      .success(.empty()),
    ])
    let client = makeClient(
      authentication: Authentication(
        provider: RecordingTokenProvider(token: "k1"), scheme: .field(apiKey)),
      transport: transport)

    try await client.executeExpectingNoContent(Request(path: "/things"))

    #expect(transport.requests.map { $0.request.headerFields[apiKey] } == ["k1", nil])
    #expect(transport.last?.request.authority == "other.example.com")
  }

  /// RFC 6454: scheme and host compare without regard to case, a port left unwritten is the
  /// scheme's default, and userinfo is no part of the origin.
  @Test(
    "a hop keeps the credential exactly when its origin is the request's",
    arguments: [
      ("/things/2", true),
      ("HTTPS://API.EXAMPLE.COM/x", true),
      ("https://api.example.com:443/x", true),
      ("https://user@api.example.com/x", true),
      ("https://api.example.com:8443/x", false),
      ("http://api.example.com/x", false),
      ("https://api.example.com.evil/x", false),
    ]
  )
  func aSameOriginHopKeepsTheCredential(location: String, kept: Bool) async throws {
    let transport = MockTransport(results: [
      .success(redirect(302, to: location)),
      .success(.empty()),
    ])
    let client = makeClient(
      authentication: Authentication(provider: RecordingTokenProvider(token: "t1")),
      transport: transport)

    try await client.executeExpectingNoContent(Request(path: "/things"))

    #expect(authorizations(of: transport) == ["Bearer t1", kept ? "Bearer t1" : nil])
  }

  @Test("a 401 at the end of a chain refreshes once and replays the request through the chain")
  func a401AtTheEndOfAChainReplays() async throws {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: "/old") { _ in
      .success(MockTransport.Answer(redirect(302, to: "/new")))
    }
    transport.setHandler(forPath: "/new") { request in
      guard request.headerFields[.authorization] == "Bearer t2" else {
        return .success(MockTransport.Answer(.empty(status: .unauthorized)))
      }
      return .success(MockTransport.Answer(.empty()))
    }
    let client = makeClient(
      authentication: Authentication(provider: tokens, refresher: tokens), transport: transport)

    try await client.executeExpectingNoContent(Request(path: "/old"))

    #expect(tokens.refreshes == 1)
    #expect(paths(of: transport) == ["/old", "/new", "/old", "/new"])
    #expect(authorizations(of: transport) == ["Bearer t1", "Bearer t1", "Bearer t2", "Bearer t2"])
  }
}

@Suite("HTTPClient redirects the policy stops", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientRedirectRefusalTests {
  @Test("a cross-origin hop under sameOrigin returns the 3xx")
  func aCrossOriginHopUnderSameOriginReturnsThe3xx() async {
    let transport = MockTransport(results: [
      .success(redirect(302, to: elsewhere)),
      .success(.empty()),
    ])
    let client = makeClient(redirectPolicy: .sameOrigin, transport: transport)

    let error = await failure {
      try await client.executeExpectingNoContent(Request(path: "/things"))
    }

    #expect(error?.statusCode == 302)
    #expect(location(of: error) == elsewhere)
    #expect(paths(of: transport) == ["/things"])
  }

  @Test("a same-origin hop under sameOrigin is followed")
  func aSameOriginHopUnderSameOriginIsFollowed() async throws {
    let transport = MockTransport(results: [
      .success(redirect(302, to: "/things/2")),
      .success(.empty()),
    ])
    let client = makeClient(redirectPolicy: .sameOrigin, transport: transport)

    try await client.executeExpectingNoContent(Request(path: "/things"))

    #expect(paths(of: transport) == ["/things", "/things/2"])
  }

  @Test("never returns the 3xx as an httpStatus failure carrying Location")
  func neverReturnsThe3xx() async {
    let transport = MockTransport(results: [
      .success(redirect(302, to: "/things/2")),
      .success(.empty()),
    ])
    let client = makeClient(redirectPolicy: .never, transport: transport)

    let error = await failure {
      try await client.executeExpectingNoContent(Request(path: "/things"))
    }

    #expect(error?.statusCode == 302)
    #expect(location(of: error) == "/things/2")
    #expect(paths(of: transport) == ["/things"])
  }

  @Test("the request's own policy takes the place of the client's")
  func theRequestsOwnPolicyWins() async throws {
    let transport = MockTransport(results: [
      .success(redirect(302, to: "/things/2")),
      .success(.empty()),
      .success(redirect(302, to: "/things/2")),
    ])

    try await makeClient(redirectPolicy: .never, transport: transport)
      .executeExpectingNoContent(
        Request(options: RequestOptions(redirectPolicy: .follow), path: "/things"))
    let error = await failure {
      try await makeClient(redirectPolicy: .follow, transport: transport)
        .executeExpectingNoContent(
          Request(options: RequestOptions(redirectPolicy: .never), path: "/things"))
    }

    #expect(paths(of: transport) == ["/things", "/things/2", "/things"])
    #expect(error?.statusCode == 302)
  }

  /// A `Location` that names no authority is not a target: `mailto:` never has one, and a bare
  /// `http:g` resolves to `http:g` under RFC 3986 5.2.2 with none.
  @Test(
    "a 3xx with no Location, or one that names no authority, is returned",
    arguments: [nil, "mailto:someone@example.com", "http:g"])
  func anUnusableLocationReturnsThe3xx(location: String?) async {
    let transport = MockTransport(results: [
      .success(redirect(302, to: location)),
      .success(.empty()),
    ])
    let client = makeClient(transport: transport)

    let error = await failure {
      try await client.executeExpectingNoContent(Request(path: "/things"))
    }

    #expect(error?.statusCode == 302)
    #expect(paths(of: transport) == ["/things"])
  }

  @Test(
    "a status that is not a redirect is never followed, Location or not", arguments: [200, 304])
  func aNonRedirectIsNotFollowed(code: Int) async throws {
    let transport = MockTransport(results: [
      .success(redirect(code, to: "/things/2")),
      .success(.empty()),
    ])
    let client = makeClient(transport: transport)

    let error = await failure {
      let response: Response = try await client.execute(Request(path: "/things"))
      return response
    }

    #expect((error?.statusCode ?? 200) == code)
    #expect(paths(of: transport) == ["/things"])
  }

  @Test("twenty-one hops stop at the twentieth and return the last 3xx")
  func twentyOneHopsStopAtTheTwentieth() async {
    let transport = MockTransport()
    transport.setHandler(forPath: "/hop") { _ in
      .success(MockTransport.Answer(redirect(302, to: "/hop")))
    }
    let client = makeClient(transport: transport)

    let error = await failure { try await client.executeExpectingNoContent(Request(path: "/hop")) }

    #expect(error?.statusCode == 302)
    #expect(location(of: error) == "/hop")
    #expect(transport.requests.count == 21)
  }
}

@Suite(
  "HTTPClient redirects as reported and as streamed", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientRedirectReportingTests {
  @Test("each hop is reported to the observer as its own send")
  func eachHopIsItsOwnSend() async throws {
    let observer = RecordingObserver()
    let transport = MockTransport(results: [
      .success(redirect(302, to: "https://other.example.com/new")),
      .success(.empty(status: .ok)),
    ])
    let client = makeClient(observer: observer, transport: transport)

    try await client.executeExpectingNoContent(Request(path: "/old"))

    let events = observer.events
    #expect(events.count == 4)
    guard events.count == 4,
      case .sent(let first) = events[0], case .received(let redirected) = events[1],
      case .sent(let second) = events[2], case .received(let final) = events[3]
    else {
      Issue.record("expected sent, received, sent, received; got \(events)")
      return
    }
    #expect(first.url == URL.fixture("https://api.example.com/old"))
    #expect(redirected.status.code == 302)
    #expect(second.url == URL.fixture("https://other.example.com/new"))
    #expect(final.status == .ok)
    let attempts: [Int] = [first.attempt, redirected.attempt, second.attempt, final.attempt]
    #expect(attempts == [1, 1, 1, 1])
    #expect(
      Set([
        first.correlationID, redirected.correlationID, second.correlationID, final.correlationID,
      ])
      .count == 1)
  }

  @Test("a hop that fails at the transport is reported under the chain's attempt and identifier")
  func aFailedHopIsReportedUnderTheSameAttempt() async {
    let observer = RecordingObserver()
    let transport = MockTransport(results: [
      .success(redirect(302, to: "/things/2")),
      .failure(.transport(kind: .connectivity, underlying: nil)),
    ])
    let client = makeClient(observer: observer, transport: transport)

    let error = await failure {
      try await client.executeExpectingNoContent(Request(path: "/things"))
    }

    guard case .transport(kind: .connectivity, underlying: nil)? = error else {
      Issue.record("expected the hop's connectivity failure, got \(String(describing: error))")
      return
    }
    let events = observer.events
    guard events.count == 4, case .sent(let first) = events[0], case .failed(let failed) = events[3]
    else {
      Issue.record("expected sent, received, sent, failed; got \(events)")
      return
    }
    #expect(failed.attempt == 1)
    #expect(failed.correlationID == first.correlationID)
    #expect(failed.url == URL.fixture("https://api.example.com/things/2"))
  }

  @Test("stream(_:) follows a redirect and delivers the final response's chunks")
  func streamFollowsARedirect() async throws {
    let transport = MockTransport(answers: [
      .success(
        MockTransport.Answer(
          chunks: [Data("moved".utf8)], headers: [.location: "/events/2"], status: .found)),
      .success(MockTransport.Answer(chunks: [Data("a".utf8), Data("b".utf8)])),
    ])
    let client = makeClient(transport: transport)

    let body = try await client.stream(Request(path: "/events"))
    var chunks: [Data] = []
    for try await chunk in body { chunks.append(chunk) }

    #expect(chunks == [Data("a".utf8), Data("b".utf8)])
    #expect(paths(of: transport) == ["/events", "/events/2"])
  }

  @Test("stream(_:) under never throws the 3xx with its body and its Location")
  func streamUnderNeverThrowsThe3xx() async {
    let transport = MockTransport(answers: [
      .success(
        MockTransport.Answer(
          chunks: [Data("moved".utf8)], headers: [.location: "/events/2"], status: .found))
    ])
    let client = makeClient(redirectPolicy: .never, transport: transport)

    let error = await failure { try await client.stream(Request(path: "/events")) }

    guard case .httpStatus(body: let body, code: 302, headers: let headers)? = error else {
      Issue.record("expected a 302 status failure, got \(String(describing: error))")
      return
    }
    #expect(body == Data("moved".utf8))
    #expect(headers[.location] == "/events/2")
  }
}
