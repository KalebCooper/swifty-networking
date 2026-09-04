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

/// A client over `MockTransport` and `RecordingClock`, defaulted apart from the arguments given here.
private func makeClient(
  baseURL: URL = URL.fixture("https://api.example.com"),
  clock: RecordingClock = RecordingClock(),
  defaultHeaders: HTTPFields = [:],
  encoder: JSONEncoder = JSONEncoder(),
  transport: MockTransport
) -> HTTPClient {
  HTTPClient(
    baseURL: baseURL,
    clock: clock,
    defaultHeaders: defaultHeaders,
    encoder: encoder,
    transport: transport
  )
}

/// The URL of each request event in the log, in order.
private func sentURLs(_ events: [RecordingObserver.Event]) -> [URL] {
  events.compactMap { if case .sent(let event) = $0 { event.url } else { nil } }
}

/// A header field name none of the client defaults set.
private let tag = HTTPField.Name.cookie

/// A value a caller decodes.
private struct Profile: Codable, Equatable {
  let id: Int
  let name: String
}

/// A value that is not `Sendable`, returned by the typed `execute` through `sending`.
private final class MutableProfile: Decodable {
  var name: String

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
  }

  private enum CodingKeys: String, CodingKey {
    case name
  }
}

/// An `Encodable` whose encoding always fails.
private struct Unencodable: Encodable {
  struct Refused: Error {}

  func encode(to encoder: any Encoder) throws {
    throw Refused()
  }
}

@Suite("HTTPClient target resolution", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientTargetTests {
  @Test(
    "the base path and the request path join with exactly one separator",
    arguments: [
      ("https://h", "users", "/users"),
      ("https://h", "/users", "/users"),
      ("https://h", "", "/"),
      ("https://h/", "users", "/users"),
      ("https://h/", "/users", "/users"),
      ("https://h/", "", "/"),
      ("https://h/v1", "users", "/v1/users"),
      ("https://h/v1", "/users", "/v1/users"),
      ("https://h/v1", "", "/v1"),
      ("https://h/v1/", "users", "/v1/users"),
      ("https://h/v1/", "/users", "/v1/users"),
      ("https://h/v1/", "", "/v1"),
      ("https://h/v1/", "users/42/posts", "/v1/users/42/posts"),
    ]
  )
  func joinMatrix(baseURL: String, path: String, expected: String) async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(baseURL: try #require(URL(string: baseURL)), transport: transport)

    try await client.executeExpectingNoContent(Request(path: path))

    #expect(transport.last?.request.path == expected)
  }

  @Test("scheme, authority, and method reach the transport as written")
  func schemeAuthorityAndMethod() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      baseURL: try #require(URL(string: "http://localhost:8080/api")), transport: transport)

    try await client.executeExpectingNoContent(Request(method: .post, path: "things"))

    let sent = try #require(transport.last?.request)
    #expect(sent.scheme == "http")
    #expect(sent.authority == "localhost:8080")
    #expect(sent.method == .post)
    #expect(sent.path == "/api/things")
  }

  @Test("query items are percent-encoded once and appended in order")
  func queryIsEncodedAndAppended() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)
    let request = Request(
      path: "search",
      query: [
        QueryItem(name: "q", value: "a b&c=d"),
        QueryItem(name: "flag"),
        QueryItem(name: "page", value: "2"),
      ]
    )

    try await client.executeExpectingNoContent(request)

    #expect(transport.last?.request.path == "/search?q=a%20b%26c%3Dd&flag&page=2")
  }

  @Test("a query on the base comes first, as written, and the request's items follow it")
  func baseQueryMergesFirst() async throws {
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])
    let client = makeClient(
      baseURL: try #require(URL(string: "https://h/v1?key=abc%3D")), transport: transport)

    try await client.executeExpectingNoContent(
      Request(path: "users", query: [QueryItem(name: "q", value: "x")]))
    #expect(transport.last?.request.path == "/v1/users?key=abc%3D&q=x")

    try await client.executeExpectingNoContent(Request(path: "users"))
    #expect(transport.last?.request.path == "/v1/users?key=abc%3D")
  }

  @Test("no query on either side leaves the target without a `?`")
  func noQueryNoSeparator() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      baseURL: try #require(URL(string: "https://h/v1?")), transport: transport)

    try await client.executeExpectingNoContent(Request(path: "users"))

    #expect(transport.last?.request.path == "/v1/users")
  }

  @Test(
    "a URL that is not a usable base fails every request with badURL before anything is sent",
    arguments: [
      "example.com", "example.com/v1", "https:/example.com", "https:///v1",
      "https://h/v1#section", "https://h?x#y",
    ]
  )
  func badBaseIsReportedPerRequest(baseURL: String) async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(baseURL: try #require(URL(string: baseURL)), transport: transport)

    let error = await failure { try await client.executeExpectingNoContent(Request(path: "users")) }

    guard case .transport(kind: .badURL, underlying: nil) = error else {
      Issue.record("expected a badURL transport failure, got \(String(describing: error))")
      return
    }
    #expect(transport.requests.isEmpty)
  }
}

@Suite("HTTPClient base URL", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientBaseURLTests {
  @Test("the base URL is stored as the URL it was given")
  func baseURLIsStored() throws {
    let base = try #require(URL(string: "https://api.example.com/v1?key=abc"))
    let client = makeClient(baseURL: base, transport: MockTransport(results: []))

    #expect(client.baseURL == base)
  }
}

@Suite("HTTPClient derived copies", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientDerivedTests {
  @Test("a client copy pointed at another transport sends through it")
  func copyPointedAtAnotherTransportSendsThroughIt() async throws {
    let original = MockTransport(results: [.success(.empty())])
    let other = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: original)
    var copy = client
    copy.transport = other

    try await client.executeExpectingNoContent(Request(path: "a"))
    try await copy.executeExpectingNoContent(Request(path: "b"))

    #expect(original.requests.map(\.request.path) == ["/a"])
    #expect(other.requests.map(\.request.path) == ["/b"])
  }

  @Test("a header field set on a copy is sent by the copy and by nobody else")
  func aDerivedHeaderFieldStaysOnTheCopy() async throws {
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])
    let client = makeClient(transport: transport)
    var derived = client
    derived.defaultHeaders[tag] = "derived"

    try await derived.executeExpectingNoContent(Request(path: "users"))
    try await client.executeExpectingNoContent(Request(path: "users"))

    #expect(transport.requests.first?.request.headerFields[tag] == "derived")
    #expect(transport.requests.last?.request.headerFields[tag] == nil)
  }

  @Test("a base URL set on a copy resolves the copy's requests against the new host")
  func aDerivedBaseURLResolvesAgainstTheNewHost() async throws {
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])
    let client = makeClient(
      baseURL: URL.fixture("https://api.example.com/v1"), transport: transport)
    var derived = client
    derived.baseURL = URL.fixture("https://other.example.com/v2")

    try await derived.executeExpectingNoContent(Request(path: "users"))
    try await client.executeExpectingNoContent(Request(path: "users"))

    #expect(transport.requests.first?.request.authority == "other.example.com")
    #expect(transport.requests.first?.request.path == "/v2/users")
    #expect(transport.requests.last?.request.authority == "api.example.com")
    #expect(transport.requests.last?.request.path == "/v1/users")
  }

  @Test("a base URL set on a copy that is not usable fails the copy's requests with badURL")
  func aDerivedBadBaseIsReportedPerRequest() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)
    var derived = client
    derived.baseURL = try #require(URL(string: "example.com"))

    let error = await failure {
      try await derived.executeExpectingNoContent(Request(path: "users"))
    }
    try await client.executeExpectingNoContent(Request(path: "users"))

    guard case .transport(kind: .badURL, underlying: nil) = error else {
      Issue.record("expected a badURL transport failure, got \(String(describing: error))")
      return
    }
    #expect(transport.requests.count == 1)
    #expect(transport.requests.first?.request.authority == "api.example.com")
  }

  @Test("an observer set on a copy receives the copy's events and none of the original's")
  func aDerivedObserverReceivesOnlyTheCopysEvents() async throws {
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])
    let inherited = RecordingObserver()
    let replacement = RecordingObserver()
    var client = makeClient(transport: transport)
    client.observer = inherited
    var derived = client
    derived.observer = replacement

    try await derived.executeExpectingNoContent(Request(path: "copies"))
    try await client.executeExpectingNoContent(Request(path: "users"))

    #expect(sentURLs(replacement.events) == [URL.fixture("https://api.example.com/copies")])
    #expect(sentURLs(inherited.events) == [URL.fixture("https://api.example.com/users")])
  }
}

@Suite("HTTPClient header fields and body", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientHeaderTests {
  @Test("default header fields are sent with a request that sets none")
  func defaultsApplied() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      defaultHeaders: [.accept: "application/json", .userAgent: "tests/1"],
      transport: transport
    )

    try await client.executeExpectingNoContent(Request(path: "users"))

    let fields = try #require(transport.last?.request.headerFields)
    #expect(fields[.accept] == "application/json")
    #expect(fields[.userAgent] == "tests/1")
  }

  @Test("a request field replaces the default of the same name and leaves the others alone")
  func requestOverridesByName() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      defaultHeaders: [.accept: "application/json", .userAgent: "tests/1"],
      transport: transport
    )

    try await client.executeExpectingNoContent(
      Request(headers: [.accept: "text/plain", tag: "one"], path: "users"))

    let fields = try #require(transport.last?.request.headerFields)
    #expect(fields[.accept] == "text/plain")
    #expect(fields[.userAgent] == "tests/1")
    #expect(fields[tag] == "one")
  }

  @Test("replacement is whole: every default value of a name goes, every request value stays")
  func multiValuedReplacement() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    var defaults = HTTPFields()
    defaults.append(HTTPField(name: tag, value: "default-a"))
    defaults.append(HTTPField(name: tag, value: "default-b"))
    let client = makeClient(defaultHeaders: defaults, transport: transport)

    var headers = HTTPFields()
    headers.append(HTTPField(name: tag, value: "request-a"))
    headers.append(HTTPField(name: tag, value: "request-b"))
    try await client.executeExpectingNoContent(Request(headers: headers, path: "users"))

    let fields = try #require(transport.last?.request.headerFields)
    #expect(fields[values: tag] == ["request-a", "request-b"])
  }

  @Test("a JSON body is encoded with the client's encoder and tagged application/json")
  func jsonBodyEncodedAndTagged() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let client = makeClient(encoder: encoder, transport: transport)
    let payload = ["zeta": "last", "alpha": "first"]

    try await client.executeExpectingNoContent(
      Request(body: .json(payload), method: .post, path: "users"))

    let call = try #require(transport.last)
    let expected = try Fixtures.json(payload)
    #expect(call.body == .bytes(expected))
    #expect(call.request.headerFields[.contentType] == "application/json")
  }

  @Test("a form body is sent as encoded pairs and tagged application/x-www-form-urlencoded")
  func formBodyEncodedAndTagged() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)

    try await client.executeExpectingNoContent(
      Request(
        body: .form([
          QueryItem(name: "email", value: "person@example.com"),
          QueryItem(name: "note", value: "tea & coffee"),
        ]),
        method: .post,
        path: "subscribers"))

    let call = try #require(transport.last)
    #expect(call.body == .bytes(Data("email=person%40example.com&note=tea+%26+coffee".utf8)))
    #expect(call.request.headerFields[.contentType] == "application/x-www-form-urlencoded")
  }

  @Test("a form body with no pairs is sent as an empty body, still tagged as a form")
  func emptyFormBodyIsAnEmptyBody() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)

    try await client.executeExpectingNoContent(
      Request(body: .form([]), method: .post, path: "subscribers"))

    let call = try #require(transport.last)
    #expect(call.body == .bytes(Data()))
    #expect(call.request.headerFields[.contentType] == "application/x-www-form-urlencoded")
  }

  @Test("a form body leaves a Content-Type the request itself carries as it was written")
  func formBodyKeepsTheRequestsContentType() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)

    try await client.executeExpectingNoContent(
      Request(
        body: .form([QueryItem(name: "vote", value: "yes")]),
        headers: [.contentType: "application/x-www-form-urlencoded; charset=utf-8"],
        method: .post,
        path: "votes"))

    let call = try #require(transport.last)
    #expect(call.body == .bytes(Data("vote=yes".utf8)))
    #expect(
      call.request.headerFields[.contentType] == "application/x-www-form-urlencoded; charset=utf-8")
  }

  @Test("a multipart body is sent as its encoded parts and tagged with the form's boundary")
  func multipartBodyEncodedAndTagged() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)

    var form = MultipartForm(boundary: "abc")
    form.append(name: "caption", value: "On the trail")
    form.append(
      contentType: "text/plain", data: Data("hello".utf8), filename: "note.txt", name: "file")

    try await client.executeExpectingNoContent(
      Request(body: .multipart(form), method: .post, path: "photos"))

    let expected = [
      "--abc\r\n",
      "Content-Disposition: form-data; name=\"caption\"\r\n",
      "\r\n",
      "On the trail\r\n",
      "--abc\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"note.txt\"\r\n",
      "Content-Type: text/plain\r\n",
      "\r\n",
      "hello\r\n",
      "--abc--\r\n",
    ].joined()
    let call = try #require(transport.last)
    #expect(call.body == .bytes(Data(expected.utf8)))
    #expect(call.request.headerFields[.contentType] == "multipart/form-data; boundary=abc")
  }

  @Test("a multipart body replaces a Content-Type the request itself carries")
  func multipartBodyReplacesTheRequestsContentType() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)

    var form = MultipartForm(boundary: "abc")
    form.append(name: "vote", value: "yes")

    try await client.executeExpectingNoContent(
      Request(
        body: .multipart(form),
        headers: [.contentType: "multipart/form-data; boundary=written-by-hand"],
        method: .post,
        path: "votes"))

    let call = try #require(transport.last)
    #expect(call.request.headerFields[.contentType] == "multipart/form-data; boundary=abc")
  }

  @Test("a multipart body replaces a Content-Type the client's default header fields carry")
  func multipartBodyReplacesTheDefaultContentType() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(
      defaultHeaders: [.contentType: "application/json"], transport: transport)

    var form = MultipartForm(boundary: "abc")
    form.append(name: "vote", value: "yes")

    try await client.executeExpectingNoContent(
      Request(body: .multipart(form), method: .post, path: "votes"))

    let call = try #require(transport.last)
    #expect(call.request.headerFields[.contentType] == "multipart/form-data; boundary=abc")
  }

  @Test("pre-encoded bytes are sent verbatim under the type the caller named")
  func bytesBodyVerbatim() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)
    let bytes = Data([0x00, 0xFF, 0x10])

    try await client.executeExpectingNoContent(
      Request(body: .bytes(bytes, contentType: "application/octet-stream"), path: "blob"))

    let call = try #require(transport.last)
    #expect(call.body == .bytes(bytes))
    #expect(call.request.headerFields[.contentType] == "application/octet-stream")
  }

  @Test("a file body is handed to the transport as its URL under the type the caller named")
  func fileBodyHandedAsURL() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)
    let file = URL.fixture("file:///uploads/recording.mp4")

    try await client.executeExpectingNoContent(
      Request(body: .file(file, contentType: "video/mp4"), method: .put, path: "recording"))

    let call = try #require(transport.last)
    #expect(call.body == .file(file))
    #expect(call.request.headerFields[.contentType] == "video/mp4")
  }

  @Test("a Content-Type already set by the caller or the defaults is kept")
  func callerContentTypeWins() async throws {
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])
    let client = makeClient(
      defaultHeaders: [.contentType: "application/vnd.api+json"], transport: transport)

    try await client.executeExpectingNoContent(
      Request(body: .json(["a": 1]), method: .post, path: "users"))
    #expect(transport.last?.request.headerFields[.contentType] == "application/vnd.api+json")

    try await client.executeExpectingNoContent(
      Request(
        body: .json(["a": 1]), headers: [.contentType: "text/json"], method: .post, path: "users"))
    #expect(transport.last?.request.headerFields[.contentType] == "text/json")
  }

  @Test("a body-less request sends no body and gains no Content-Type")
  func noBodyNoContentType() async throws {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(defaultHeaders: [.accept: "*/*"], transport: transport)

    try await client.executeExpectingNoContent(Request(path: "users"))

    let call = try #require(transport.last)
    #expect(call.body == .none)
    #expect(call.request.headerFields[.contentType] == nil)
  }

  @Test("the client hands the transport the request's cache policy")
  func cachePolicyHandedToTransport() async throws {
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])
    let client = makeClient(transport: transport)

    try await client.executeExpectingNoContent(
      Request(options: RequestOptions(cachePolicy: .ignoreCache), path: "prices"))
    #expect(transport.last?.options == TransportOptions(cachePolicy: .ignoreCache))

    try await client.executeExpectingNoContent(Request(path: "prices"))
    #expect(transport.last?.options == TransportOptions())
  }

  @Test("a body that cannot be encoded fails as such, and nothing is sent")
  func encodeFailureSendsNothing() async {
    let transport = MockTransport(results: [.success(.empty())])
    let client = makeClient(transport: transport)

    let error = await failure {
      try await client.executeExpectingNoContent(
        Request(body: .json(Unencodable()), method: .post, path: "users"))
    }

    guard case .encode(let underlying) = error else {
      Issue.record("expected an encode failure, got \(String(describing: error))")
      return
    }
    #expect(underlying is Unencodable.Refused)
    #expect(transport.requests.isEmpty)
  }
}

@Suite("HTTPClient entry points", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientExecuteTests {
  @Test("the typed entry point decodes a JSON body")
  func typedDecodes() async throws {
    let expected = Profile(id: 7, name: "Ada")
    let transport = MockTransport(results: [.success(.ok(json: try Fixtures.json(expected)))])
    let client = makeClient(transport: transport)

    let profile: Profile = try await client.execute(Request(path: "profile"))

    #expect(profile == expected)
  }

  @Test("the raw entry point returns the successful response exactly as delivered")
  func rawReturnsUntouched() async throws {
    let seeded = Response.json(
      Data("[1,2,3]".utf8), headers: [.eTag: "\"v1\""], status: .created)
    let transport = MockTransport(results: [.success(seeded)])
    let client = makeClient(transport: transport)

    let response = try await client.execute(Request(path: "items"))

    #expect(response == seeded)
  }

  @Test(
    "a status outside 2xx is thrown as httpStatus by every entry point",
    arguments: [
      HTTPResponse.Status.movedPermanently, .notModified, .badRequest, .unauthorized, .notFound,
      .internalServerError, .serviceUnavailable,
    ]
  )
  func nonSuccessThrowsEverywhere(status: HTTPResponse.Status) async throws {
    let body = Fixtures.jsonObject(["error": "nope"])
    let seeded = Response.json(body, headers: [.retryAfter: "30"], status: status)
    let transport = MockTransport(results: [
      .success(seeded), .success(seeded), .success(seeded), .success(seeded),
    ])
    let client = makeClient(transport: transport)
    let request = Request(path: "thing")

    let raw = await failure { try await client.execute(request) as Response }
    let typed = await failure { try await client.execute(request) as Profile }
    let noContent = await failure { try await client.executeExpectingNoContent(request) }
    let headered = await failure {
      try await client.execute(request) as DecodedResponse<Profile>
    }

    for error in [raw, typed, noContent, headered] {
      guard case .httpStatus(body: let thrownBody, code: let code, headers: let headers) = error
      else {
        Issue.record("expected httpStatus, got \(String(describing: error))")
        continue
      }
      #expect(code == status.code)
      #expect(thrownBody == body)
      #expect(headers[.retryAfter] == "30")
      #expect(headers[.contentType] == "application/json")
    }
    #expect(transport.requests.count == 4)
  }

  @Test(
    "a successful body the typed entry point cannot decode is a decode failure",
    arguments: ["", "not json", "{\"id\":\"seven\",\"name\":\"Ada\"}", "{\"id\":7}"]
  )
  func undecodableBodyIsDecodeFailure(body: String) async {
    let transport = MockTransport(results: [.success(.json(Data(body.utf8), status: .ok))])
    let client = makeClient(transport: transport)

    let error = await failure { try await client.execute(Request(path: "profile")) as Profile }

    guard case .decode(let underlying) = error else {
      Issue.record("expected a decode failure, got \(String(describing: error))")
      return
    }
    #expect(underlying is DecodingError)
  }

  @Test(
    "the no-content entry point accepts any 2xx, with or without a body",
    arguments: [
      Response.empty(), .empty(status: .ok), .ok(json: Fixtures.jsonObject(["ok": "true"])),
      .text("done", status: .accepted),
    ]
  )
  func noContentAcceptsEverySuccess(seeded: Response) async throws {
    let transport = MockTransport(results: [.success(seeded)])
    let client = makeClient(transport: transport)

    try await client.executeExpectingNoContent(Request(method: .delete, path: "things/1"))

    #expect(transport.requests.count == 1)
  }

  @Test("a transport failure passes through unchanged")
  func transportFailurePassesThrough() async {
    let transport = MockTransport(results: [
      .failure(.transport(kind: .timedOut, underlying: nil)),
      .failure(.cancelled),
    ])
    let client = makeClient(transport: transport)

    let timeout = await failure { try await client.execute(Request(path: "a")) as Response }
    let cancelled = await failure { try await client.execute(Request(path: "a")) as Response }

    #expect(timeout?.isTimeout == true)
    #expect(cancelled?.description == "cancelled")
  }

  @Test("a decoded value need not be Sendable: it is handed back as sending")
  func decodedValueIsSent() async throws {
    let transport = MockTransport(results: [
      .success(.ok(json: Fixtures.jsonObject(["name": "Ada"])))
    ])
    let client = makeClient(transport: transport)

    let profile: MutableProfile = try await client.execute(Request(path: "profile"))
    profile.name = "Grace"

    #expect(profile.name == "Grace")
  }

  @Test("the client is callable from the main actor and hands a non-Sendable value back there")
  @MainActor
  func callableFromMainActor() async throws {
    let transport = MockTransport(results: [
      .success(.ok(json: Fixtures.jsonObject(["name": "Ada"])))
    ])
    let client = makeClient(transport: transport)

    let profile: MutableProfile = try await client.execute(Request(path: "profile"))

    #expect(profile.name == "Ada")
  }

  @Test("a client that was given no retry policy sends once and never waits")
  func singleAttemptNoSleep() async {
    let transport = MockTransport(results: [
      .failure(.transport(kind: .timedOut, underlying: nil))
    ])
    let clock = RecordingClock()
    let client = makeClient(clock: clock, transport: transport)

    let error = await failure { try await client.execute(Request(path: "a")) as Response }

    #expect(error?.isTimeout == true)
    #expect(transport.requests.count == 1)
    #expect(clock.sleeps.isEmpty)
    #expect(clock.pendingSleeps == 0)
  }

  @Test("the client is Sendable, and a copy sends through the same transport")
  func clientIsSendableValue() async throws {
    requireSendable(HTTPClient.self)
    let transport = MockTransport(results: [.success(.empty()), .success(.empty())])
    let client = makeClient(transport: transport)
    let copy = client

    try await client.executeExpectingNoContent(Request(path: "a"))
    try await copy.executeExpectingNoContent(Request(path: "b"))

    #expect(transport.requests.map(\.request.path) == ["/a", "/b"])
  }
}
