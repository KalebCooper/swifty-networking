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

/// The three pages of an XML-shaped listing, first to last. Each names the marker of the page after
/// it, and the last names none.
private let listingPages = [
  "<page>1</page>\n<marker>m2</marker>\n",
  "<page>2</page>\n<marker>m3</marker>\n",
  "<page>3</page>\n",
]

/// A line of a listing page that is not a `<name>value</name>` element.
private struct LineFormatError: Error, Equatable {
  let line: String
}

/// A page that is neither `Decodable` nor `Sendable`.
private final class Listing {
  var fields: [String: String]

  init(fields: [String: String]) {
    self.fields = fields
  }
}

/// A snake_case JSON page, decoded through a client whose decoder converts from snake case.
private struct ItemPage: Decodable, Equatable {
  let nextCursor: String?
  let pageNumber: String
}

/// A listing page's fields together with the whole response they were read from.
private struct Receipt: Sendable {
  let fields: [String: String]
  let response: Response

  init(_ response: Response) throws {
    fields = try elements(in: response.body)
    self.response = response
  }
}

/// Every response a decode closure was handed and every error it caught, in the order they arrived.
private final class DecodeLog: Sendable {
  private struct State {
    var failures: [any Error] = []
    var responses: [Response] = []
  }

  private let state = Mutex(State())

  var failures: [any Error] {
    state.withLock { $0.failures }
  }

  var responses: [Response] {
    state.withLock { $0.responses }
  }

  func record(_ response: Response) {
    state.withLock { $0.responses.append(response) }
  }

  func record(failure: any Error) {
    state.withLock { $0.failures.append(failure) }
  }
}

/// Reads a body of one `<name>value</name>` element per line into a dictionary, the way a source
/// codec would, without any XML parser.
private func elements(in body: Data) throws(LineFormatError) -> [String: String] {
  var fields: [String: String] = [:]
  for line in String(decoding: body, as: UTF8.self).split(separator: "\n") {
    guard line.hasPrefix("<"), let open = line.firstIndex(of: ">") else {
      throw LineFormatError(line: String(line))
    }
    let name = line[line.index(after: line.startIndex)..<open]
    let close = "</\(name)>"
    guard !name.isEmpty, line.hasSuffix(close) else { throw LineFormatError(line: String(line)) }
    fields[String(name)] = String(
      line[line.index(after: open)..<line.index(line.endIndex, offsetBy: -close.count)])
  }
  return fields
}

/// A `200 OK` listing page with the body `text` and the entity tag `tag`.
private func listingPage(_ text: String, tag: String) -> Response {
  Response(
    body: Data(text.utf8), headers: [.contentType: "application/xml", .eTag: tag], status: .ok)
}

/// The page after the one whose fields are `fields`, named by its `marker` field, sent as a copy of
/// `request` with that marker.
private func markerPage(_ fields: [String: String], after request: Request) -> NextPage? {
  fields["marker"].map { marker in
    var next = request
    next.query = [QueryItem(name: "marker", value: marker)]
    return .request(next)
  }
}

/// A client on `https://api.example.com` whose decoder converts snake_case keys.
private func snakeCaseClient(transport: MockTransport) -> HTTPClient {
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  return HTTPClient(
    baseURL: URL.fixture("https://api.example.com"), decoder: decoder, transport: transport)
}

@Suite("PageSequence decode closure", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct PageSequenceDecodeTests {
  @Test("A custom decode receives each page's own bytes, header fields, and status, in order")
  func customDecodeReceivesEachPagesResponse() async throws {
    let transport = MockTransport(results: [
      .success(listingPage(listingPages[0], tag: "\"p1\"")),
      .success(listingPage(listingPages[1], tag: "\"p2\"")),
      .success(listingPage(listingPages[2], tag: "\"p3\"")),
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let objects = client.pages(
      Request(path: "/objects"), as: Receipt.self, decode: { response in try Receipt(response) }
    ) { page, request in markerPage(page.value.fields, after: request) }

    var pages: [DecodedResponse<Receipt>] = []
    for try await page in objects {
      pages.append(page)
    }

    try #require(pages.count == 3)
    #expect(
      pages.map(\.value.response.body) == [
        Data("<page>1</page>\n<marker>m2</marker>\n".utf8),
        Data("<page>2</page>\n<marker>m3</marker>\n".utf8),
        Data("<page>3</page>\n".utf8),
      ])
    #expect(pages.map { $0.value.response.headers[.eTag] } == ["\"p1\"", "\"p2\"", "\"p3\""])
    #expect(pages.map(\.value.response.status) == [.ok, .ok, .ok])
    #expect(pages.map { $0.headers[.eTag] } == ["\"p1\"", "\"p2\"", "\"p3\""])
    #expect(pages.map(\.status) == [.ok, .ok, .ok])
    #expect(pages.map { $0.value.fields["page"] } == ["1", "2", "3"])
  }

  @Test("A value the custom decode produces drives next, with exactly one request per page read")
  func decodedValueDrivesNextOneRequestPerRead() async throws {
    let log = DecodeLog()
    let transport = MockTransport(results: [
      .success(listingPage(listingPages[0], tag: "\"p1\"")),
      .success(listingPage(listingPages[1], tag: "\"p2\"")),
      .success(listingPage(listingPages[2], tag: "\"p3\"")),
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let objects = client.pages(
      Request(path: "/objects"), as: [String: String].self,
      decode: { response in
        log.record(response)
        return try elements(in: response.body)
      }
    ) { page, request in markerPage(page.value, after: request) }

    var iterator = objects.makeAsyncIterator()
    _ = try await iterator.next()
    #expect(paths(of: transport) == ["/objects"])
    #expect(log.responses.count == 1)
    _ = try await iterator.next()
    #expect(paths(of: transport) == ["/objects", "/objects?marker=m2"])
    #expect(log.responses.count == 2)
    let third = try await iterator.next()
    #expect(paths(of: transport) == ["/objects", "/objects?marker=m2", "/objects?marker=m3"])
    #expect(log.responses.count == 3)
    let after = try await iterator.next()

    #expect(third?.value["page"] == "3")
    #expect(after == nil)
    #expect(transport.requests.count == 3)
  }

  @Test("Breaking after the first page sends no second request")
  func earlyBreakSendsNoSecondRequest() async throws {
    let log = DecodeLog()
    let transport = MockTransport(results: [
      .success(listingPage(listingPages[0], tag: "\"p1\"")),
      .success(listingPage(listingPages[1], tag: "\"p2\"")),
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let objects = client.pages(
      Request(path: "/objects"), as: [String: String].self,
      decode: { response in
        log.record(response)
        return try elements(in: response.body)
      }
    ) { page, request in markerPage(page.value, after: request) }

    var first: String?
    for try await page in objects {
      first = page.value["page"]
      break
    }

    #expect(first == "1")
    #expect(paths(of: transport) == ["/objects"])
    #expect(log.responses.count == 1)
  }

  @Test("An error the custom decode throws ends the sequence as a decode failure carrying it")
  func codecErrorEndsTheSequenceAsDecode() async throws {
    let transport = MockTransport(results: [
      .success(listingPage("<page>1</page>\nnot an element\n", tag: "\"p1\""))
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let objects = client.pages(
      Request(path: "/objects"), as: [String: String].self,
      decode: { response in try elements(in: response.body) }
    ) { page, request in markerPage(page.value, after: request) }

    var iterator = objects.makeAsyncIterator()
    let error = await failure { try await iterator.next() }
    let after = try await iterator.next()

    guard case .decode(let underlying) = try #require(error) else {
      Issue.record("expected a decode failure, got \(String(describing: error))")
      return
    }
    #expect(underlying as? LineFormatError == LineFormatError(line: "not an element"))
    #expect(after == nil)
    #expect(transport.requests.count == 1)
  }

  @Test(
    "A TransportError the custom decode throws passes through unchanged",
    arguments: [
      .decode(underlying: LineFormatError(line: "passed through")),
      .httpStatus(body: Data("gone".utf8), code: 410, headers: [:]),
    ] as [TransportError]
  )
  func transportErrorPassesThrough(thrown: TransportError) async throws {
    let transport = MockTransport(results: [.success(listingPage(listingPages[2], tag: "\"p3\""))])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let objects = client.pages(
      Request(path: "/objects"), as: [String: String].self,
      decode: { _ in throw thrown }
    ) { page, request in markerPage(page.value, after: request) }

    var iterator = objects.makeAsyncIterator()
    let error = await failure { try await iterator.next() }

    switch (thrown, try #require(error)) {
    case (.decode, .decode(let underlying)):
      #expect(underlying as? LineFormatError == LineFormatError(line: "passed through"))
    case (.httpStatus, .httpStatus(let body, let code, let headers)):
      #expect(body == Data("gone".utf8))
      #expect(code == 410)
      #expect(headers == [:])
    default:
      Issue.record("expected \(thrown) unchanged, got \(String(describing: error))")
    }
  }

  @Test("A non-2xx page throws its status and the custom decode is never called")
  func nonSuccessPageSkipsTheDecode() async throws {
    let log = DecodeLog()
    let transport = MockTransport(results: [
      .success(
        Response(
          body: Data("<error>missing</error>\n".utf8), headers: [.contentType: "application/xml"],
          status: .notFound))
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let objects = client.pages(
      Request(path: "/objects"), as: [String: String].self,
      decode: { response in
        log.record(response)
        return try elements(in: response.body)
      }
    ) { page, request in markerPage(page.value, after: request) }

    var iterator = objects.makeAsyncIterator()
    let error = await failure { try await iterator.next() }
    let after = try await iterator.next()

    #expect(statusCode(error) == 404)
    #expect(after == nil)
    #expect(log.responses.isEmpty)
  }

  @Test("A reader cancelled between pages reads cancelled, sends nothing, and decodes nothing more")
  func cancellationBetweenPages() async throws {
    let log = DecodeLog()
    let transport = MockTransport(results: [
      .success(listingPage(listingPages[0], tag: "\"p1\"")),
      .success(listingPage(listingPages[1], tag: "\"p2\"")),
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let objects = client.pages(
      Request(path: "/objects"), as: [String: String].self,
      decode: { response in
        log.record(response)
        return try elements(in: response.body)
      }
    ) { page, request in markerPage(page.value, after: request) }
    let (firstPages, delivered) = AsyncStream.makeStream(of: String?.self)
    // Never yielded to: the reader parks on it after the first page until its task is cancelled,
    // which ends an `AsyncStream` iteration, so the cancellation is in place before the next read.
    let (gate, gateOpener) = AsyncStream.makeStream(of: Void.self)

    let reader = Task { () async throws -> TransportError? in
      var iterator = objects.makeAsyncIterator()
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
    #expect(log.responses.count == 1)
  }

  /// The decode enters, signals entry, then parks on a gate until the test opens it. Cancelling the
  /// reader while it is parked there ends that `AsyncStream` iteration, so `checkCancellation`
  /// afterwards throws, and the read must still answer `.cancelled` because the reading task is
  /// cancelled.
  @Test("A reader cancelled while the custom decode runs reads cancelled")
  func cancellationDuringDecode() async throws {
    let log = DecodeLog()
    let transport = MockTransport(results: [.success(listingPage(listingPages[0], tag: "\"p1\""))])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let (entered, didEnter) = AsyncStream.makeStream(of: Void.self)
    // Never yielded to: the decode parks on it after entering until its task is cancelled, which
    // ends an `AsyncStream` iteration, so the cancellation is in place before `checkCancellation`.
    let (gate, gateOpener) = AsyncStream.makeStream(of: Void.self)
    // Finished on every path, so a reader that never reaches the gate leaves nothing parked.
    defer { gateOpener.finish() }
    let objects = client.pages(
      Request(path: "/objects"), as: [String: String].self,
      decode: { response in
        log.record(response)
        didEnter.yield()
        for await _ in gate {}
        do {
          try Task.checkCancellation()
        } catch {
          log.record(failure: error)
          throw error
        }
        return try elements(in: response.body)
      }
    ) { page, request in markerPage(page.value, after: request) }

    let reader = Task { () async -> TransportError? in
      var iterator = objects.makeAsyncIterator()
      return await failure { try await iterator.next() }
    }
    var enteredIterator = entered.makeAsyncIterator()
    _ = await enteredIterator.next()
    reader.cancel()
    let error = await reader.value

    if case .cancelled = try #require(error) {
    } else {
      Issue.record("expected cancelled, got \(String(describing: error))")
    }
    #expect(log.responses.count == 1)
    #expect(log.failures.count == 1)
    #expect(log.failures.first is CancellationError)
    #expect(transport.requests.count == 1)
  }

  /// Proves `PageSequence<Value>` carries no `Sendable` bound on `Value`, and that `decode`'s result
  /// lands in the reading task's own isolation: it runs on the main actor here because the read
  /// itself does, not because the sequence forces it there.
  @MainActor
  @Test("A value that is neither Decodable nor Sendable is read page by page on the main actor")
  func nonDecodableNonSendableValueOnTheMainActor() async throws {
    let transport = MockTransport(results: [
      .success(listingPage(listingPages[0], tag: "\"p1\"")),
      .success(listingPage(listingPages[1], tag: "\"p2\"")),
      .success(listingPage(listingPages[2], tag: "\"p3\"")),
    ])
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let objects = client.pages(
      Request(path: "/objects"), as: Listing.self,
      decode: { response in Listing(fields: try elements(in: response.body)) }
    ) { page, request in markerPage(page.value.fields, after: request) }

    var numbers: [String?] = []
    for try await page in objects {
      numbers.append(page.value.fields["page"])
    }

    #expect(numbers == ["1", "2", "3"])
    #expect(paths(of: transport) == ["/objects", "/objects?marker=m2", "/objects?marker=m3"])
  }

  /// Both readers join one exchange for the keyed first page, and every later page is two sends,
  /// so three pages read by two readers are six decodes over five sends. A decode shared between
  /// readers would show fewer decodes; a later page shared would show fewer sends and leave a
  /// release waiting on two parked sends until the suite's time limit fails it.
  @Test("Two concurrent readers of one sequence each decode every page they read")
  func concurrentReadersEachDecodeTheirPages() async throws {
    let clock = RecordingClock()
    let log = DecodeLog()
    let mock = MockTransport()
    mock.setHandler(forPath: "/objects") { request in
      switch request.path {
      case "/objects":
        .success(MockTransport.Answer(listingPage(listingPages[0], tag: "\"p1\"")))
      case "/objects?marker=m2":
        .success(MockTransport.Answer(listingPage(listingPages[1], tag: "\"p2\"")))
      default:
        .success(MockTransport.Answer(listingPage(listingPages[2], tag: "\"p3\"")))
      }
    }
    let client = HTTPClient(
      baseURL: URL.fixture("https://api.example.com"), clock: clock,
      transport: HoldingTransport(clock: clock, inner: mock))
    let keyed = Request(options: RequestOptions(coalescingKey: "objects"), path: "/objects")
    let objects = client.pages(
      keyed, as: [String: String].self,
      decode: { response in
        log.record(response)
        return try elements(in: response.body)
      }
    ) { page, _ in markerPage(page.value, after: keyed) }

    // `Task.immediate` runs each reader to its first suspension in turn, so the first leads the
    // keyed exchange and the second has joined it before any send is released.
    let readers: [Task<[String?], any Error>] = (0..<2).map { _ in
      Task.immediate { () async throws -> [String?] in
        var seen: [String?] = []
        for try await page in objects {
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
    #expect(log.responses.count == 6)
    #expect(
      log.responses.map { String(decoding: $0.body, as: UTF8.self) }.sorted() == [
        "<page>1</page>\n<marker>m2</marker>\n", "<page>1</page>\n<marker>m2</marker>\n",
        "<page>2</page>\n<marker>m3</marker>\n", "<page>2</page>\n<marker>m3</marker>\n",
        "<page>3</page>\n", "<page>3</page>\n",
      ])
    #expect(
      paths(of: mock) == [
        "/objects", "/objects?marker=m2", "/objects?marker=m2", "/objects?marker=m3",
        "/objects?marker=m3",
      ])
  }

  @Test("Two iterations of one sequence, one after the other, each start from the first page")
  func sequentialIterationsStartOver() async throws {
    let log = DecodeLog()
    let transport = MockTransport()
    transport.setHandler(forPath: "/objects") { request in
      switch request.path {
      case "/objects":
        .success(MockTransport.Answer(listingPage(listingPages[0], tag: "\"p1\"")))
      case "/objects?marker=m2":
        .success(MockTransport.Answer(listingPage(listingPages[1], tag: "\"p2\"")))
      default:
        .success(MockTransport.Answer(listingPage(listingPages[2], tag: "\"p3\"")))
      }
    }
    let client = HTTPClient(baseURL: URL.fixture("https://api.example.com"), transport: transport)
    let objects = client.pages(
      Request(path: "/objects"), as: [String: String].self,
      decode: { response in
        log.record(response)
        return try elements(in: response.body)
      }
    ) { page, request in markerPage(page.value, after: request) }

    var runs: [[String?]] = []
    for _ in 0..<2 {
      var seen: [String?] = []
      for try await page in objects {
        seen.append(page.value["page"])
      }
      runs.append(seen)
    }

    #expect(runs == [["1", "2", "3"], ["1", "2", "3"]])
    #expect(log.responses.count == 6)
    #expect(
      paths(of: transport) == [
        "/objects", "/objects?marker=m2", "/objects?marker=m3",
        "/objects", "/objects?marker=m2", "/objects?marker=m3",
      ])
  }

  @Test("pages(_:as:next:) still decodes with the client's own JSONDecoder")
  func jsonPagesUseTheClientDecoder() async throws {
    let transport = MockTransport(results: [
      .success(.ok(json: Fixtures.jsonObject(["next_cursor": "c2", "page_number": "1"]))),
      .success(.ok(json: Fixtures.jsonObject(["page_number": "2"]))),
    ])
    let client = snakeCaseClient(transport: transport)
    let items = client.pages(Request(path: "/items"), as: ItemPage.self) { page, request in
      page.value.nextCursor.map { cursor in
        var next = request
        next.query = [QueryItem(name: "cursor", value: cursor)]
        return .request(next)
      }
    }

    var values: [ItemPage] = []
    for try await page in items {
      values.append(page.value)
    }

    #expect(
      values == [
        ItemPage(nextCursor: "c2", pageNumber: "1"), ItemPage(nextCursor: nil, pageNumber: "2"),
      ])
    #expect(paths(of: transport) == ["/items", "/items?cursor=c2"])
  }

  @Test("pages(_:next:) infers the page type from the next closure's parameter, as before")
  func jsonPagesInferTheTypeFromNext() async throws {
    let transport = MockTransport(results: [
      .success(.ok(json: Fixtures.jsonObject(["page_number": "1"])))
    ])
    let client = snakeCaseClient(transport: transport)
    let items = client.pages(Request(path: "/items")) {
      (page: DecodedResponse<ItemPage>, _: Request) -> NextPage? in
      page.value.nextCursor.map { .link($0) }
    }

    var values: [ItemPage] = []
    for try await page in items {
      values.append(page.value)
    }

    #expect(values == [ItemPage(nextCursor: nil, pageNumber: "1")])
    #expect(transport.requests.count == 1)
  }

  @Test("The JSON initializer and the decode initializer over the same pages yield equal pages")
  func jsonAndDecodeInitializersAgree() async throws {
    let log = DecodeLog()
    let transport = MockTransport()
    transport.setHandler(forPath: "/items") { request in
      switch request.path {
      case "/items":
        .success(
          MockTransport.Answer(
            .ok(
              headers: [.eTag: "\"i1\""],
              json: Fixtures.jsonObject(["next_cursor": "c2", "page_number": "1"]))))
      default:
        .success(
          MockTransport.Answer(
            .ok(headers: [.eTag: "\"i2\""], json: Fixtures.jsonObject(["page_number": "2"]))))
      }
    }
    let client = snakeCaseClient(transport: transport)
    let next: @Sendable (DecodedResponse<ItemPage>, Request) -> NextPage? = { page, request in
      page.value.nextCursor.map { cursor in
        var next = request
        next.query = [QueryItem(name: "cursor", value: cursor)]
        return .request(next)
      }
    }
    let json = PageSequence<ItemPage>(client: client, next: next, request: Request(path: "/items"))
    let custom = PageSequence<ItemPage>(
      client: client,
      decode: { response in
        log.record(response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ItemPage.self, from: response.body)
      },
      next: next, request: Request(path: "/items"))

    var jsonPages: [DecodedResponse<ItemPage>] = []
    for try await page in json {
      jsonPages.append(page)
    }
    var customPages: [DecodedResponse<ItemPage>] = []
    for try await page in custom {
      customPages.append(page)
    }

    let expected = [
      ItemPage(nextCursor: "c2", pageNumber: "1"), ItemPage(nextCursor: nil, pageNumber: "2"),
    ]
    #expect(jsonPages.map(\.value) == expected)
    #expect(customPages.map(\.value) == expected)
    #expect(jsonPages.map(\.headers) == customPages.map(\.headers))
    #expect(jsonPages.map { $0.headers[.eTag] } == ["\"i1\"", "\"i2\""])
    #expect(jsonPages.map(\.status) == customPages.map(\.status))
    #expect(jsonPages.map(\.status) == [.ok, .ok])
    #expect(
      log.responses.map(\.body) == [
        Data(#"{"next_cursor":"c2","page_number":"1"}"#.utf8), Data(#"{"page_number":"2"}"#.utf8),
      ])
    #expect(
      paths(of: transport) == ["/items", "/items?cursor=c2", "/items", "/items?cursor=c2"])
  }
}
