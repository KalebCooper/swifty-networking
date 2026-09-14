import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A page whose decoded value is a reference type the compiler cannot treat as `Sendable`.
private final class ClassPage: Decodable {
  let next: String?
  let number: String
}

/// The page after `page`, named by its `cursor` field, sent as a copy of `request` with that cursor.
private func cursorPage(_ page: DecodedResponse<[String: String]>, after request: Request)
  -> NextPage?
{
  page.value["cursor"].map { cursor in
    var next = request
    next.query = [QueryItem(name: "cursor", value: cursor)]
    return .request(next)
  }
}

/// The page named by the first `Link` field value whose relations include `next`.
private func linkedPage(_ page: DecodedResponse<[String: String]>) -> NextPage? {
  WebLink.links(in: page.headers)
    .first { $0.relations.contains("next") }
    .map { .link($0.target) }
}

@Suite("PageSequence", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct PageSequenceTests {
  @Test("A cursor in the body fetches three pages in order, then the sequence ends")
  func cursorPagesInOrder() async throws {
    let transport = MockTransport(results: [
      .success(.ok(json: Fixtures.jsonObject(["cursor": "c2", "page": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["cursor": "c3", "page": "2"]))),
      .success(.ok(json: Fixtures.jsonObject(["page": "3"]))),
    ])
    let client = HTTPClient(
      baseURL: URL.fixture("https://api.example.com/v1"), transport: transport)
    let first = Request(options: RequestOptions(coalescingKey: "items"), path: "/items")
    let items = client.pages(first, as: [String: String].self) { page, request in
      #expect(request.options.coalescingKey == nil)
      return cursorPage(page, after: request)
    }

    var seen: [String?] = []
    for try await page in items {
      seen.append(page.value["page"])
    }

    #expect(seen == ["1", "2", "3"])
    #expect(paths(of: transport) == ["/v1/items", "/v1/items?cursor=c2", "/v1/items?cursor=c3"])
  }

  @Test("A relative next link resolves against the page's URL, then the sequence ends")
  func relativeLinkPages() async throws {
    let link = try #require(HTTPField.Name("Link"))
    let transport = MockTransport(results: [
      .success(
        .ok(
          headers: [link: "</v1/items?page=2>; rel=\"next\""],
          json: Fixtures.jsonObject(["page": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["page": "2"]))),
    ])
    let client = HTTPClient(
      baseURL: URL.fixture("https://api.example.com/v1"), transport: transport)
    let first = Request(options: RequestOptions(coalescingKey: "items"), path: "/items")
    let issues = client.pages(first, as: [String: String].self) { page, request in
      #expect(request.options.coalescingKey == nil)
      return linkedPage(page)
    }

    var seen: [String?] = []
    for try await page in issues {
      seen.append(page.value["page"])
    }

    #expect(seen == ["1", "2"])
    #expect(paths(of: transport) == ["/v1/items", "/v1/items?page=2"])
    #expect(transport.last?.request.authority == "api.example.com")
  }

  @Test("An absolute next link is fetched with GET and no body, keeping the header fields")
  func absoluteLinkIsFetchedWithGETAndNoBody() async throws {
    let link = try #require(HTTPField.Name("Link"))
    let trace = try #require(HTTPField.Name("X-Trace"))
    let transport = MockTransport(results: [
      .success(
        .ok(
          headers: [link: "<https://api.example.com/search?page=2>; rel=\"next\""],
          json: Fixtures.jsonObject(["page": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["page": "2"]))),
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let search = Request(
      body: .form([QueryItem(name: "q", value: "swift")]), headers: [trace: "abc"], method: .post,
      path: "/search")
    let results = client.pages(search, as: [String: String].self) { page, _ in linkedPage(page) }

    var seen: [String?] = []
    for try await page in results {
      seen.append(page.value["page"])
    }

    #expect(seen == ["1", "2"])
    #expect(paths(of: transport) == ["/search", "/search?page=2"])
    let sent = transport.requests
    try #require(sent.count == 2)
    #expect(sent[0].request.method == .post)
    #expect(sent[0].body != TransportBody.none)
    #expect(sent[1].request.method == .get)
    #expect(sent[1].body == TransportBody.none)
    #expect(sent[1].request.headerFields[trace] == "abc")
  }

  @Test("A linked page drops Content-Type and Content-Length and keeps every other header field")
  func linkedPageDropsBodyHeaderFields() async throws {
    let link = try #require(HTTPField.Name("Link"))
    let trace = try #require(HTTPField.Name("X-Trace"))
    let transport = MockTransport(results: [
      .success(
        .ok(
          headers: [link: "</items?page=2>; rel=\"next\""],
          json: Fixtures.jsonObject(["page": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["page": "2"]))),
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let upload = Request(
      body: .bytes(Data("{}".utf8), contentType: "application/json"),
      headers: [.contentLength: "2", .contentType: "application/json", trace: "abc"],
      method: .post, path: "/items")
    let items = client.pages(upload, as: [String: String].self) { page, _ in linkedPage(page) }

    var seen: [String?] = []
    for try await page in items {
      seen.append(page.value["page"])
    }

    #expect(seen == ["1", "2"])
    let sent = transport.requests
    try #require(sent.count == 2)
    #expect(sent[0].request.headerFields[.contentLength] == "2")
    #expect(sent[0].request.headerFields[.contentType] == "application/json")
    #expect(sent[1].request.method == .get)
    #expect(sent[1].request.headerFields[.contentLength] == nil)
    #expect(sent[1].request.headerFields[.contentType] == nil)
    #expect(sent[1].request.headerFields[trace] == "abc")
  }

  @Test("A relative next link reached after a redirect resolves against the redirected URL")
  func relativeLinkAfterRedirect() async throws {
    let link = try #require(HTTPField.Name("Link"))
    let transport = MockTransport(results: [
      .success(
        Response(headers: [.location: "https://api.example.com/v2/items/"], status: .found)),
      .success(
        .ok(headers: [link: "<page2>; rel=\"next\""], json: Fixtures.jsonObject(["page": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["page": "2"]))),
    ])
    let client = HTTPClient(
      baseURL: URL.fixture("https://api.example.com/v1"), transport: transport)
    let items = client.pages(Request(path: "/items"), as: [String: String].self) { page, _ in
      linkedPage(page)
    }

    var seen: [String?] = []
    for try await page in items {
      seen.append(page.value["page"])
    }

    #expect(seen == ["1", "2"])
    #expect(paths(of: transport) == ["/v1/items", "/v2/items/", "/v2/items/page2"])
  }

  /// The credential follows the base's origin, as it does across a redirect; a custom header field
  /// the caller wrote on the request, one that carries no credential, travels to every page
  /// wherever it lives.
  @Test(
    "A linked page carries the credential only on the base's origin, and a custom header field to every page",
    arguments: [
      ("https://cdn.example.com/items?page=2", nil),
      ("https://api.example.com/items?page=2", "Bearer t1"),
    ] as [(String, String?)]
  )
  func linkedPageCredentialFollowsOrigin(target: String, credential: String?) async throws {
    let link = try #require(HTTPField.Name("Link"))
    let trace = try #require(HTTPField.Name("X-Trace"))
    let transport = MockTransport(results: [
      .success(
        .ok(
          headers: [link: "<\(target)>; rel=\"next\""], json: Fixtures.jsonObject(["page": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["page": "2"]))),
    ])
    let client = HTTPClient(
      authentication: Authentication(provider: RecordingTokenProvider(token: "t1")),
      baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let items = client.pages(
      Request(headers: [trace: "abc"], path: "/items"), as: [String: String].self
    ) { page, _ in linkedPage(page) }

    var seen: [String?] = []
    for try await page in items {
      seen.append(page.value["page"])
    }

    #expect(seen == ["1", "2"])
    #expect(authorizations(of: transport) == ["Bearer t1", credential])
    #expect(transport.requests.map { $0.request.headerFields[trace] } == ["abc", "abc"])
  }

  @Test(
    "A linked page on another origin goes without the caller's Authorization, Cookie, and Proxy-Authorization, keeping X-Trace"
  )
  func crossOriginLinkedPageWithholdsCallerCredentialFields() async throws {
    let link = try #require(HTTPField.Name("Link"))
    let trace = try #require(HTTPField.Name("X-Trace"))
    let transport = MockTransport(results: [
      .success(
        .ok(
          headers: [link: "<https://cdn.example.com/items?page=2>; rel=\"next\""],
          json: Fixtures.jsonObject(["page": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["page": "2"]))),
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let request = Request(
      headers: [
        .authorization: "Basic abc", .cookie: "session=1", .proxyAuthorization: "Basic proxy",
        trace: "abc",
      ],
      path: "/items")
    let items = client.pages(request, as: [String: String].self) { page, _ in linkedPage(page) }

    var seen: [String?] = []
    for try await page in items {
      seen.append(page.value["page"])
    }

    #expect(seen == ["1", "2"])
    let sent = transport.requests.map(\.request.headerFields)
    try #require(sent.count == 2)
    #expect(sent[0][.authorization] == "Basic abc")
    #expect(sent[0][.cookie] == "session=1")
    #expect(sent[0][.proxyAuthorization] == "Basic proxy")
    #expect(sent[1][.authorization] == nil)
    #expect(sent[1][.cookie] == nil)
    #expect(sent[1][.proxyAuthorization] == nil)
    #expect(sent.map { $0[trace] } == ["abc", "abc"])
  }

  @Test("A linked page on another origin that answers 401 throws it without a refresh")
  func crossOriginLinkedPage401DoesNotRefresh() async throws {
    let link = try #require(HTTPField.Name("Link"))
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport(results: [
      .success(
        .ok(
          headers: [link: "<https://cdn.example.com/items?page=2>; rel=\"next\""],
          json: Fixtures.jsonObject(["page": "1"]))),
      .success(.empty(status: .unauthorized)),
    ])
    let client = HTTPClient(
      authentication: Authentication(provider: tokens, refresher: tokens),
      baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let items = client.pages(Request(path: "/items"), as: [String: String].self) { page, _ in
      linkedPage(page)
    }

    var iterator = items.makeAsyncIterator()
    let first = try await iterator.next()
    let error = await failure { try await iterator.next() }

    #expect(first?.value["page"] == "1")
    #expect(statusCode(error) == 401)
    #expect(tokens.refreshes == 0)
    #expect(authorizations(of: transport) == ["Bearer t1", nil])
  }

  @Test(
    "A linked page on another origin that redirects to a third origin answering 401 throws it without a refresh"
  )
  func crossOriginLinkedPageRedirectedOffOriginDoesNotRefresh() async throws {
    let link = try #require(HTTPField.Name("Link"))
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport(results: [
      .success(
        .ok(
          headers: [link: "<https://cdn.example.com/moved>; rel=\"next\""],
          json: Fixtures.jsonObject(["page": "1"]))),
      .success(Response(headers: [.location: "https://other.example.com/page2"], status: .found)),
      .success(.empty(status: .unauthorized)),
    ])
    let client = HTTPClient(
      authentication: Authentication(provider: tokens, refresher: tokens),
      baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let items = client.pages(Request(path: "/items"), as: [String: String].self) { page, _ in
      linkedPage(page)
    }

    var iterator = items.makeAsyncIterator()
    let first = try await iterator.next()
    let error = await failure { try await iterator.next() }

    #expect(first?.value["page"] == "1")
    #expect(statusCode(error) == 401)
    #expect(tokens.refreshes == 0)
    #expect(paths(of: transport) == ["/items", "/moved", "/page2"])
    #expect(
      transport.requests.map(\.request.authority)
        == ["api.example.com", "cdn.example.com", "other.example.com"])
    #expect(authorizations(of: transport) == ["Bearer t1", nil, nil])
  }

  @Test(
    "A linked page on another origin that redirects to the base's origin and meets a 401 refreshes and replays"
  )
  func crossOriginLinkedPageRedirectedToTheBaseRefreshes() async throws {
    let link = try #require(HTTPField.Name("Link"))
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("t2")], token: "t1")
    let transport = MockTransport()
    transport.setHandler(forPath: "/items") { _ in
      .success(
        MockTransport.Answer(
          .ok(
            headers: [link: "<https://cdn.example.com/moved>; rel=\"next\""],
            json: Fixtures.jsonObject(["page": "1"]))))
    }
    transport.setHandler(forPath: "/moved") { _ in
      .success(
        MockTransport.Answer(
          Response(headers: [.location: "https://api.example.com/page2"], status: .found)))
    }
    transport.setHandler(forPath: "/page2") { request in
      guard request.headerFields[.authorization] == "Bearer t2" else {
        return .success(MockTransport.Answer(.empty(status: .unauthorized)))
      }
      return .success(MockTransport.Answer(.ok(json: Fixtures.jsonObject(["page": "2"]))))
    }
    let client = HTTPClient(
      authentication: Authentication(provider: tokens, refresher: tokens),
      baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let items = client.pages(Request(path: "/items"), as: [String: String].self) { page, _ in
      page.value["page"] == "1" ? linkedPage(page) : nil
    }

    var seen: [String?] = []
    for try await page in items {
      seen.append(page.value["page"])
    }

    #expect(seen == ["1", "2"])
    #expect(tokens.refreshes == 1)
    #expect(paths(of: transport) == ["/items", "/moved", "/page2", "/moved", "/page2"])
    #expect(authorizations(of: transport) == ["Bearer t1", nil, "Bearer t1", nil, "Bearer t2"])
  }

  @Test("A non-2xx second page throws its status after the first page, then the sequence ends")
  func nonSuccessOnSecondPage() async throws {
    let transport = MockTransport(results: [
      .success(.ok(json: Fixtures.jsonObject(["cursor": "c2", "page": "1"]))),
      .success(.json(Fixtures.jsonObject(["error": "missing"]), status: .notFound)),
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let items = client.pages(Request(path: "/items"), as: [String: String].self) { page, request in
      cursorPage(page, after: request)
    }

    var iterator = items.makeAsyncIterator()
    let first = try await iterator.next()
    let error = await failure { try await iterator.next() }
    let after = try await iterator.next()

    #expect(first?.value["page"] == "1")
    #expect(statusCode(error) == 404)
    #expect(after == nil)
    #expect(transport.requests.count == 2)
  }

  @Test("A body that does not decode ends the sequence with a decode failure")
  func decodeFailureEndsTheSequence() async throws {
    let transport = MockTransport(results: [.success(.ok(json: Data("not json".utf8)))])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let items = client.pages(Request(path: "/items"), as: [String: String].self) { page, request in
      cursorPage(page, after: request)
    }

    var iterator = items.makeAsyncIterator()
    let error = await failure { try await iterator.next() }
    let after = try await iterator.next()

    if case .decode = try #require(error) {
    } else {
      Issue.record("expected a decode failure, got \(String(describing: error))")
    }
    #expect(after == nil)
  }

  @Test("A reader cancelled between pages reads cancelled, and no further page is sent")
  func cancellationBetweenPages() async throws {
    let transport = MockTransport(results: [
      .success(.ok(json: Fixtures.jsonObject(["cursor": "c2", "page": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["page": "2"]))),
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let items = client.pages(Request(path: "/items"), as: [String: String].self) { page, request in
      cursorPage(page, after: request)
    }
    let (firstPages, delivered) = AsyncStream.makeStream(of: String?.self)
    // Never yielded to: the reader parks on it after the first page until its task is cancelled,
    // which ends an `AsyncStream` iteration, so the cancellation is in place before the next read.
    let (gate, gateOpener) = AsyncStream.makeStream(of: Void.self)

    let reader = Task { () async throws -> TransportError? in
      var iterator = items.makeAsyncIterator()
      let first = try await iterator.next()
      delivered.yield(first?.value["page"])
      for await _ in gate {}
      return await failure { try await iterator.next() }
    }
    var firsts = firstPages.makeAsyncIterator()
    let first = await firsts.next()
    reader.cancel()
    let error = try await reader.value
    gateOpener.finish()

    #expect(first == "1")
    if case .cancelled = try #require(error) {
    } else {
      Issue.record("expected cancelled, got \(String(describing: error))")
    }
    #expect(transport.requests.count == 1)
  }

  /// Cancelling the reader wakes page 2's parked hold, which the holding transport reports as a
  /// `.transport(kind: .other, ...)` failure. Retrying is disabled and there is no deadline, so that
  /// failure is what the client throws, and the read must still answer `.cancelled`.
  @Test("A failure reported on a cancelled reader's task reads as cancelled")
  func failureOnACancelledTaskReadsCancelled() async throws {
    let clock = RecordingClock()
    let mock = MockTransport(results: [
      .success(.ok(json: Fixtures.jsonObject(["cursor": "c2", "page": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["page": "2"]))),
    ])
    let client = HTTPClient(
      baseURL: URL.fixture("https://api.example.com"), clock: clock,
      transport: HoldingTransport(clock: clock, inner: mock))
    let items = client.pages(Request(path: "/items"), as: [String: String].self) { page, request in
      cursorPage(page, after: request)
    }

    let reader = Task { () async throws -> (first: String?, error: TransportError?) in
      var iterator = items.makeAsyncIterator()
      let first = try await iterator.next()
      let error = await failure { try await iterator.next() }
      return (first?.value["page"], error)
    }
    await clock.waitForPendingSleep()
    clock.advanceAll()
    await clock.waitForPendingSleep()
    reader.cancel()
    let outcome = try await reader.value

    #expect(outcome.first == "1")
    if case .cancelled = try #require(outcome.error) {
    } else {
      Issue.record("expected cancelled, got \(String(describing: outcome.error))")
    }
    #expect(paths(of: mock) == ["/items"])
  }

  /// `https:items` resolves to itself, an absolute reference with no authority, so the `badURL` comes
  /// from the client's absolute-destination check when the second page is resolved, before anything
  /// is sent, and not from the sequence's own resolution.
  @Test("A link that names no authority returns the page, then throws badURL, then ends")
  func unresolvableLinkThrowsBadURL() async throws {
    let link = try #require(HTTPField.Name("Link"))
    let transport = MockTransport(results: [
      .success(
        .ok(
          headers: [link: "<https:items>; rel=\"next\""], json: Fixtures.jsonObject(["page": "1"])))
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let items = client.pages(Request(path: "/items"), as: [String: String].self) { page, _ in
      linkedPage(page)
    }

    var iterator = items.makeAsyncIterator()
    let first = try await iterator.next()
    let error = await failure { try await iterator.next() }
    let after = try await iterator.next()

    #expect(first?.value["page"] == "1")
    #expect(isBadURL(error))
    #expect(after == nil)
    #expect(transport.requests.count == 1)
  }

  @Test("Nothing is sent until the first read, which sends one request")
  func nothingSentBeforeTheFirstRead() async throws {
    let transport = MockTransport(results: [.success(.ok(json: Fixtures.jsonObject(["page": "1"])))]
    )
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let items = client.pages(Request(path: "/items"), as: [String: String].self) { page, request in
      cursorPage(page, after: request)
    }

    var iterator = items.makeAsyncIterator()
    #expect(transport.requests.isEmpty)
    let first = try await iterator.next()

    #expect(first?.value["page"] == "1")
    #expect(transport.requests.count == 1)
  }

  @Test("Each page reports one willSend and didReceive pair under its own correlation identifier")
  func observerPairPerPage() async throws {
    let observer = RecordingObserver()
    let transport = MockTransport(results: [
      .success(.ok(json: Fixtures.jsonObject(["cursor": "c2", "page": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["cursor": "c3", "page": "2"]))),
      .success(.ok(json: Fixtures.jsonObject(["page": "3"]))),
    ])
    let client = HTTPClient(
      baseURL: URL.fixture("https://api.example.com"), observer: observer, transport: transport)
    let items = client.pages(Request(path: "/items"), as: [String: String].self) { page, request in
      cursorPage(page, after: request)
    }

    for try await _ in items {}

    let reported: [(kind: String, correlationID: String)] = observer.events.map { event in
      switch event {
      case .failed(let failure): ("failed", failure.correlationID)
      case .finishedBody(let body): ("finishedBody", body.correlationID)
      case .received(let response): ("received", response.correlationID)
      case .sent(let request): ("sent", request.correlationID)
      }
    }
    #expect(reported.map(\.kind) == ["sent", "received", "sent", "received", "sent", "received"])
    try #require(reported.count == 6)
    for page in 0..<3 {
      #expect(reported[2 * page].correlationID == reported[2 * page + 1].correlationID)
    }
    #expect(Set(reported.map(\.correlationID)).count == 3)
  }

  /// Both readers join one exchange for the first page, which is sent with its key. Every later page
  /// must be two sends, so each release waits for two parked sends; a key carried onto a later page
  /// would join them into one, and that wait would then hang until the suite's time limit fails it,
  /// the same trade `answerWaits` makes.
  @Test("Two concurrent readers of one sequence share only the keyed first page and see every page")
  func concurrentReadersUnderContention() async throws {
    let clock = RecordingClock()
    let mock = MockTransport()
    mock.setHandler(forPath: "/items") { request in
      switch request.path {
      case "/items":
        .success(
          MockTransport.Answer(.ok(json: Fixtures.jsonObject(["cursor": "c2", "page": "1"]))))
      case "/items?cursor=c2":
        .success(
          MockTransport.Answer(.ok(json: Fixtures.jsonObject(["cursor": "c3", "page": "2"]))))
      default:
        .success(MockTransport.Answer(.ok(json: Fixtures.jsonObject(["page": "3"]))))
      }
    }
    let client = HTTPClient(
      baseURL: URL.fixture("https://api.example.com"), clock: clock,
      transport: HoldingTransport(clock: clock, inner: mock))
    let keyed = Request(options: RequestOptions(coalescingKey: "items"), path: "/items")
    // Each following request is built from the keyed one, so the sequence is what clears the key.
    let items = client.pages(keyed, as: [String: String].self) { page, request in
      #expect(request.options.coalescingKey == nil)
      return cursorPage(page, after: keyed)
    }

    // `Task.immediate` runs each reader to its first suspension in turn, so the first leads the
    // keyed exchange and the second has joined it before any send is released.
    let readers: [Task<[String?], any Error>] = (0..<2).map { _ in
      Task.immediate { () async throws -> [String?] in
        var seen: [String?] = []
        for try await page in items {
          seen.append(page.value["page"])
        }
        return seen
      }
    }
    await clock.waitForPendingSleep()
    #expect(mock.requests.isEmpty)
    clock.advanceAll()
    await clock.waitForPendingSleep(count: 2)
    clock.advanceAll()
    await clock.waitForPendingSleep(count: 2)
    clock.advanceAll()

    for reader in readers {
      #expect(try await reader.value == ["1", "2", "3"])
    }
    #expect(
      paths(of: mock) == [
        "/items", "/items?cursor=c2", "/items?cursor=c2", "/items?cursor=c3", "/items?cursor=c3",
      ])
  }

  @Test("The request handed to next after a link has no coalescing key and keeps the other options")
  func linkedRequestKeepsOptionsWithoutTheKey() async throws {
    let link = try #require(HTTPField.Name("Link"))
    let clock = RecordingClock()
    let transport = MockTransport(results: [
      .success(
        .ok(
          headers: [link: "</items?page=2>; rel=\"next\""],
          json: Fixtures.jsonObject(["page": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["page": "2"]))),
    ])
    let client = HTTPClient(
      baseURL: URL.fixture("https://api.example.com"), clock: clock, transport: transport)
    let keyed = Request(
      options: RequestOptions(
        cachePolicy: .ignoreCache, coalescingKey: "items", redirectPolicy: .sameOrigin,
        requiresAuth: false, retryPolicy: RetryPolicy(backoff: .zero, maxAttempts: 2),
        timeout: .seconds(30)),
      path: "/items")
    let items = client.pages(keyed, as: [String: String].self) { page, request in
      if page.value["page"] == "2" {
        #expect(request.options.coalescingKey == nil)
        #expect(request.options.cachePolicy == .ignoreCache)
        #expect(request.options.redirectPolicy == .sameOrigin)
        #expect(request.options.requiresAuth == false)
        #expect(request.options.retryPolicy?.maxAttempts == 2)
        #expect(request.options.timeout == .seconds(30))
      }
      return linkedPage(page)
    }

    var seen: [String?] = []
    for try await page in items {
      seen.append(page.value["page"])
    }

    #expect(seen == ["1", "2"])
    #expect(paths(of: transport) == ["/items", "/items?page=2"])
  }

  @MainActor
  @Test("A value that is not Sendable is read page by page on the main actor")
  func nonSendableValueOnTheMainActor() async throws {
    let transport = MockTransport(results: [
      .success(.ok(json: Fixtures.jsonObject(["next": "2", "number": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["number": "2"]))),
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let pages = client.pages(Request(path: "/items"), as: ClassPage.self) { page, request in
      page.value.next.map { number in
        var next = request
        next.query = [QueryItem(name: "page", value: number)]
        return .request(next)
      }
    }

    var numbers: [String] = []
    for try await page in pages {
      numbers.append(page.value.number)
    }

    #expect(numbers == ["1", "2"])
    #expect(paths(of: transport) == ["/items", "/items?page=2"])
  }
}
