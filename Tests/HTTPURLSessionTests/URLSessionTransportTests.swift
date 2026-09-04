// `URLSessionTransport` exists only where URLSession does, so this suite compiles away on other
// platforms.
#if canImport(Darwin)

import Foundation
import HTTPCore
import HTTPTesting
import HTTPTypes
import HTTPURLSession
import Synchronization
import Testing

/// The URL every fixture sends to.
private let endpoint = "https://example.com/v1/things"

/// The URL every fixture sends to, as a value.
private let endpointURL = URL.fixture("https://example.com/v1/things")

/// Where a scripted redirect points.
private let elsewhere = "https://example.com/v1/elsewhere"

/// The body kinds a buffered send chooses a session call by.
enum BodyKind: Sendable {
  case bytes
  case file
  case none
}

/// A request carrying a scheme and an authority, so a URL can be built from it.
private func target(
  headerFields: HTTPFields = [:],
  method: HTTPRequest.Method = .get,
  path: String = "/v1/things"
) -> HTTPRequest {
  HTTPRequest(
    method: method, scheme: "https", authority: "example.com", path: path,
    headerFields: headerFields)
}

/// A session whose requests `script` answers, and the transport that sends through it.
///
/// The caller holds on to both: the session so it can be invalidated, and the script because its
/// `deinit` unregisters its answers, which would otherwise happen while a request is still in flight.
private func makeTransport(_ script: StubURLProtocol.Script) -> (URLSession, URLSessionTransport) {
  let session = URLSession(configuration: script.makeSessionConfiguration())
  return (session, URLSessionTransport(session: session))
}

/// A session whose requests the given protocol answers, and the transport that sends through it.
///
/// The protocol is installed on this configuration alone and never registered process-wide, so tests
/// running in parallel cannot answer one another's requests. The protocols below hold no state for the
/// same reason, except the one latch a single test waits on.
private func makeTransport(answeredBy protocolClass: AnyClass) -> (URLSession, URLSessionTransport)
{
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [protocolClass]
  let session = URLSession(configuration: configuration)
  return (session, URLSessionTransport(session: session))
}

/// The HTTP response a test-local protocol answers with: `200`, no header fields.
private func okResponse(for request: URLRequest) -> HTTPURLResponse? {
  guard let url = request.url else { return nil }
  return HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
}

/// A `URLProtocol` that answers with a `URLResponse` that is not an HTTP one, the way the loading
/// system answers a `file:` or `data:` URL. `StubURLProtocol` cannot script this, since every answer it
/// takes is HTTP-shaped.
private final class NonHTTPURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let client else { return }
    guard let url = request.url else {
      client.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let response = URLResponse(
      url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: "utf-8")
    client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client.urlProtocolDidFinishLoading(self)
  }

  /// Does nothing: the answer is delivered before ``startLoading()`` returns, so nothing is in flight.
  override func stopLoading() {}
}

/// A `URLProtocol` that answers with an `HTTPURLResponse` carrying a status no HTTP response takes.
/// `HTTPURLResponse` stores the status and returns it unchanged, so the response is HTTP-shaped and
/// still carries no status that can be read.
private final class UnrepresentableStatusURLProtocol: URLProtocol {
  /// The status delivered, one past the last a response can carry.
  static let status = 1000

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let client else { return }
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: [:])
    else {
      client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client.urlProtocolDidFinishLoading(self)
  }

  /// Does nothing: the answer is delivered before ``startLoading()`` returns, so nothing is in flight.
  override func stopLoading() {}
}

/// A `URLProtocol` that never answers and records nothing, so a task loaded through it runs until it
/// is cancelled and nothing reaches its delegate but what a test delivers by hand.
private final class IdleURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {}

  /// Does nothing: nothing was ever delivered, so there is nothing to stop.
  override func stopLoading() {}
}

/// A `URLProtocol` that never answers, so a caller stays parked on the response until it is
/// cancelled. Each load arrives at ``started``, which is what lets a test cancel a request only once
/// the loading system has taken it; one test uses this protocol, so the count it waits for is exact.
private final class NeverAnsweringURLProtocol: URLProtocol {
  /// Where every load arrives before it hangs.
  static let started = Latch()

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.started.arrive()
  }

  /// Does nothing: nothing was ever delivered, so there is nothing to stop.
  override func stopLoading() {}
}

/// The error a send failed with, or `nil` when it returned a response.
private func failure(
  sending request: HTTPRequest,
  body: TransportBody = .none,
  options: TransportOptions = TransportOptions(),
  through transport: URLSessionTransport
) async -> TransportError? {
  do {
    _ = try await transport.send(request, body: body, options: options)
    return nil
  } catch {
    return error
  }
}

/// Whether the error is ``TransportError/cancelled``.
private func isCancelled(_ error: TransportError) -> Bool {
  if case .cancelled = error { true } else { false }
}

/// The failure kind and wrapped error of a transport failure, or `nil` for any other case.
private func transportFailure(_ error: TransportError) -> (TransportFailureKind, (any Error)?)? {
  if case .transport(let kind, let underlying) = error { (kind, underlying) } else { nil }
}

/// The body as a string.
private func text(_ data: Data) -> String {
  String(decoding: data, as: UTF8.self)
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct URLSessionTransportResponseTests {
  @Test func statusHeadersAndBodyReachTheCaller() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data("hello".utf8), headers: ["Content-Type": "text/plain"], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let response = try await transport.send(target(), body: .none, options: TransportOptions())

    #expect(response.status.code == 200)
    #expect(response.headers[.contentType] == "text/plain")
    #expect(text(response.body) == "hello")
    #expect(script.requests.count == 1)
  }

  @Test(arguments: [200, 201, 204, 301, 400, 401, 404, 409, 429, 500, 503])
  func everyStatusIsReturnedRatherThanThrown(status: Int) async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: status)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let response = try await transport.send(target(), body: .none, options: TransportOptions())

    #expect(response.status.code == status)
    #expect(script.requests.count == 1)
  }

  /// The three body kinds each take a different session call, and each call is given the delegate.
  @Test(
    "URLSessionTransport returns a 3xx instead of following it",
    arguments: [BodyKind.none, .bytes, .file])
  func aRedirectIsReturnedNotFollowed(kind: BodyKind) async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data("moved".utf8), headers: ["Location": elsewhere], status: 302),
      .response(body: Data(), headers: [:], status: 200),
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }
    let body: TransportBody =
      switch kind {
      case .bytes: .bytes(Data("payload".utf8))
      case .file: .file(try temporaryFile(Data("payload".utf8)))
      case .none: .none
      }

    let response = try await transport.send(
      target(method: kind == .none ? .get : .post), body: body, options: TransportOptions())

    #expect(response.status.code == 302)
    #expect(response.headers[.location] == elsewhere)
    #expect(text(response.body) == "moved")
    #expect(script.requests.count == 1)
  }

  @Test func requestHeaderFieldsAndBodyGoOutAsGiven() async throws {
    let marker = try #require(HTTPField.Name("X-Request-Marker"))
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }
    var headerFields = HTTPFields()
    headerFields[.authorization] = "Bearer token"
    headerFields[marker] = "1"

    _ = try await transport.send(
      target(headerFields: headerFields, method: .post), body: .bytes(Data(#"{"id":1}"#.utf8)),
      options: TransportOptions())

    // Asserted field by field because `StubURLProtocol` leaves its own routing header in the
    // recorded request.
    let call = try #require(script.last)
    #expect(call.request.httpMethod == "POST")
    #expect(call.request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    #expect(call.request.value(forHTTPHeaderField: "X-Request-Marker") == "1")
    #expect(call.body.map(text) == #"{"id":1}"#)
  }

  @Test func aBodylessRequestSendsNoBody() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    _ = try await transport.send(target(), body: .none, options: TransportOptions())

    // Which of the two send calls carried this is not visible here, so what is pinned is the request
    // that went out: no bytes to read back, and no length announced.
    let call = try #require(script.last)
    #expect(call.body == nil)
    #expect(call.request.value(forHTTPHeaderField: "Content-Length") == nil)
  }

  @Test func aBodyGoesOutThroughTheUploadPathAsGiven() async throws {
    let payload = Data(#"{"id":1}"#.utf8)
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    _ = try await transport.send(
      target(method: .put), body: .bytes(payload), options: TransportOptions())

    let call = try #require(script.last)
    #expect(call.request.httpMethod == "PUT")
    #expect(call.body == payload)
    #expect(call.request.value(forHTTPHeaderField: "Content-Length") == "\(payload.count)")
  }

  @Test func anEmptyBodyIsIndistinguishableFromNoBody() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    _ = try await transport.send(
      target(method: .post), body: .bytes(Data()), options: TransportOptions())

    // An empty body puts nothing on the wire and announces no length, exactly as no body does, so
    // there is no special case for one.
    let call = try #require(script.last)
    #expect(call.body == nil)
    #expect(call.request.value(forHTTPHeaderField: "Content-Length") == nil)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct URLSessionTransportFailureTests {
  @Test(arguments: [
    (URLError.Code.badURL, TransportFailureKind.badURL),
    (URLError.Code.unsupportedURL, TransportFailureKind.badURL),
    (URLError.Code.networkConnectionLost, TransportFailureKind.connectivity),
    (URLError.Code.notConnectedToInternet, TransportFailureKind.connectivity),
    (URLError.Code.timedOut, TransportFailureKind.timedOut),
    (URLError.Code.cannotFindHost, TransportFailureKind.other),
    (URLError.Code.secureConnectionFailed, TransportFailureKind.other),
  ])
  func eachURLErrorCodeMapsToItsKind(code: URLError.Code, expected: TransportFailureKind)
    async throws
  {
    let script = StubURLProtocol.Script(answers: [.failure(code: code, failingURL: nil)])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let error = try #require(await failure(sending: target(), through: transport))

    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == expected)
    #expect((underlying as? URLSessionTransportFailure)?.code == code)
    #expect(script.requests.count == 1)
  }

  @Test func aCancelledRequestIsTheCancellationCaseAndNotAKind() async throws {
    let script = StubURLProtocol.Script(answers: [.failure(code: .cancelled, failingURL: nil)])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let error = try #require(await failure(sending: target(), through: transport))

    #expect(isCancelled(error))
    #expect(error.underlying == nil)
    #expect(script.requests.count == 1)
  }

  @Test func aCancelledSendCarryingABodyIsAlsoTheCancellationCase() async throws {
    let script = StubURLProtocol.Script(answers: [.failure(code: .cancelled, failingURL: nil)])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    // A request with a body takes the upload call, which reports a cancelled caller the same way a
    // body-less send does.
    let error = try #require(
      await failure(
        sending: target(method: .post), body: .bytes(Data(#"{"id":1}"#.utf8)), through: transport))

    #expect(isCancelled(error))
    #expect(error.underlying == nil)
    #expect(script.requests.count == 1)
  }

  @Test func aCallerCancelledBeforeSendingLeavesWithCancelled() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    // A task added to an already-cancelled group starts cancelled, which is deterministic where
    // racing a `cancel()` fired alongside it is not.
    let outcome = await withTaskGroup(of: TransportError?.self) { group in
      group.cancelAll()
      group.addTask { await failure(sending: target(), through: transport) }
      return await group.next() ?? nil
    }

    #expect(isCancelled(try #require(outcome)))
    #expect(script.requests.count <= 1)
  }

  @Test func aRequestWithNoURLToSendToIsABadURL() async throws {
    let script = StubURLProtocol.Script()
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }
    // No scheme and no authority, so no URL can be built from it and nothing is sent.
    let unsendable = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/v1/things")

    let error = try #require(await failure(sending: unsendable, through: transport))

    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .badURL)
    #expect(underlying == nil)
    #expect(script.requests.isEmpty)
  }

  @Test func anErrorThatIsNotAURLErrorIsCarriedThroughAsOther() async throws {
    // Nothing is scripted, so `StubURLProtocol` fails the request with an error from a domain that has
    // no mapping of its own.
    let script = StubURLProtocol.Script()
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let error = try #require(await failure(sending: target(), through: transport))

    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .other)
    // Read back with the initializer, never a cast: the loading system rebuilds the error as a plain
    // `NSError` on its way out.
    #expect(StubURLProtocolFailure(try #require(underlying)) == .noCannedResponse)
    #expect(script.requests.count == 1)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct URLSessionTransportRedactionTests {
  /// The signature a signed URL carries, which is the part that must never reach a log.
  private static let credential = "s3cr3t-signature"

  @Test func aFailureDescribesItselfWithoutTheSignedQuery() async throws {
    let failingURL = try #require(URL(string: "\(endpoint)?sig=\(Self.credential)&expires=1"))
    let script = StubURLProtocol.Script(answers: [
      .failure(code: .timedOut, failingURL: failingURL)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let error = try #require(await failure(sending: target(), through: transport))

    let (_, underlying) = try #require(transportFailure(error))
    let wrapped = try #require(underlying as? URLSessionTransportFailure)
    #expect(!"\(wrapped)".contains(Self.credential))
    #expect(!"\(wrapped)".contains("sig="))
    #expect("\(wrapped)".contains(endpoint))
    #expect(!error.description.contains(Self.credential))
    #expect(wrapped.urlError.failingURL == failingURL)
    #expect(wrapped.code == .timedOut)
    #expect(script.requests.count == 1)
  }

  @Test func aFailureWithNoURLIsDescribedByItsCodeAlone() async throws {
    let script = StubURLProtocol.Script(answers: [
      .failure(code: .notConnectedToInternet, failingURL: nil)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let error = try #require(await failure(sending: target(), through: transport))

    let (_, underlying) = try #require(transportFailure(error))
    let wrapped = try #require(underlying as? URLSessionTransportFailure)
    #expect("\(wrapped)" == "URLSession error \(URLError.Code.notConnectedToInternet.rawValue)")
    #expect(script.requests.count == 1)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes)))
struct URLSessionTransportUnreadableResponseTests {
  /// The signature a signed URL carries, which is the part that must never reach a log.
  private static let credential = "s3cr3t-signature"

  @Test func aResponseThatIsNotHTTPNamesWhatArrivedInstead() async throws {
    let (session, transport) = makeTransport(answeredBy: NonHTTPURLProtocol.self)
    defer { session.finishTasksAndInvalidate() }

    let error = try #require(await failure(sending: target(), through: transport))

    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .other)
    let unreadable = try #require(underlying as? URLSessionResponseFailure)
    guard case .notHTTP(let responseType, let url) = unreadable else {
      Issue.record("expected a non-HTTP response, got \(unreadable)")
      return
    }
    #expect(responseType.contains("URLResponse"))
    #expect(url?.absoluteString == endpoint)
    #expect("\(unreadable)".contains(responseType))
    #expect("\(unreadable)".contains(endpoint))
  }

  @Test func aStatusNoResponseRepresentsIsReportedWithTheStatusItCarried() async throws {
    let (session, transport) = makeTransport(answeredBy: UnrepresentableStatusURLProtocol.self)
    defer { session.finishTasksAndInvalidate() }

    let error = try #require(await failure(sending: target(), through: transport))

    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .other)
    let unreadable = try #require(underlying as? URLSessionResponseFailure)
    guard case .unrepresentableStatus(let code, let url) = unreadable else {
      Issue.record("expected an unrepresentable status, got \(unreadable)")
      return
    }
    #expect(code == UnrepresentableStatusURLProtocol.status)
    #expect(url?.absoluteString == endpoint)
    #expect("\(unreadable)".contains("\(UnrepresentableStatusURLProtocol.status)"))
  }

  @Test func anUnreadableResponseDescribesItselfWithoutTheSignedQuery() async throws {
    let (session, transport) = makeTransport(answeredBy: NonHTTPURLProtocol.self)
    defer { session.finishTasksAndInvalidate() }
    let signed = target(path: "/v1/things?sig=\(Self.credential)&expires=1")

    let error = try #require(await failure(sending: signed, through: transport))

    let (_, underlying) = try #require(transportFailure(error))
    let unreadable = try #require(underlying as? URLSessionResponseFailure)
    #expect(!"\(unreadable)".contains(Self.credential))
    #expect(!"\(unreadable)".contains("sig="))
    #expect("\(unreadable)".contains(endpoint))
    #expect(!error.description.contains(Self.credential))
    guard case .notHTTP(responseType: _, let url) = unreadable else {
      Issue.record("expected a non-HTTP response, got \(unreadable)")
      return
    }
    #expect(url?.query() == "sig=\(Self.credential)&expires=1")
  }
}

/// The bytes of a streamed body, read to the end.
private func collect(
  _ body: some AsyncSequence<Data, TransportError>
) async throws(TransportError) -> [UInt8] {
  var collected: [UInt8] = []
  for try await chunk in body { collected.append(contentsOf: chunk) }
  return collected
}

/// The failure a streamed request produced before any byte was delivered, or `nil` when it produced a
/// response. A failure reported from the returned sequence is a different thing, so the body is not
/// read here.
private func streamFailure(
  sending request: HTTPRequest,
  body: TransportBody = .none,
  through transport: URLSessionTransport
) async -> TransportError? {
  do {
    _ = try await transport.stream(request, body: body, options: TransportOptions())
    return nil
  } catch {
    return error
  }
}

/// Every chunk of a streamed body and the failure that ended it, if one did.
private func drain(_ body: StreamedBody) async -> (received: [Data], failure: TransportError?) {
  var chunks: [Data] = []
  do throws(TransportError) {
    for try await chunk in body {
      chunks.append(chunk)
    }
    return (chunks, nil)
  } catch {
    return (chunks, error)
  }
}

/// The streaming half of `URLSessionTransport`, over the same stub the tests above send through.
///
/// A task loaded through any `URLProtocol` receives nothing until the protocol finishes or fails,
/// and then everything at once: the response, every load as one chunk, and the completion. So a
/// stub can prove what a whole load delivers and what a request that never answers does, and
/// nothing about a body still arriving. Chunk boundaries, a failure after the response, dropping
/// a body mid-load, and flow control are proven at the delegate, in the suite below.
@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct URLSessionTransportStreamingTests {
  @Test func statusHeadersAndBodyReachTheCaller() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data("hello".utf8), headers: ["Content-Type": "text/plain"], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let response = try await transport.stream(target(), body: .none, options: TransportOptions())

    #expect(response.status.code == 200)
    #expect(response.headers[.contentType] == "text/plain")
    #expect(try await collect(response.body) == Array("hello".utf8))
    #expect(script.requests.count == 1)
  }

  @Test func theBytesArriveInTheOrderTheOriginSentThem() async throws {
    let sent = Array(UInt8(0)...UInt8(255))
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(sent), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let response = try await transport.stream(target(), body: .none, options: TransportOptions())

    #expect(try await collect(response.body) == sent)
    #expect(script.requests.count == 1)
  }

  @Test(arguments: [200, 201, 204, 301, 400, 401, 404, 409, 429, 500, 503])
  func everyStatusIsReturnedRatherThanThrown(status: Int) async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data("body".utf8), headers: [:], status: status)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let response = try await transport.stream(target(), body: .none, options: TransportOptions())

    #expect(response.status.code == status)
    #expect(try await collect(response.body) == Array("body".utf8))
    #expect(script.requests.count == 1)
  }

  @Test("URLSessionTransport returns a 3xx instead of following it")
  func aRedirectIsReturnedNotFollowed() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data("moved".utf8), headers: ["Location": elsewhere], status: 302),
      .response(body: Data(), headers: [:], status: 200),
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let response = try await transport.stream(target(), body: .none, options: TransportOptions())

    #expect(response.status.code == 302)
    #expect(response.headers[.location] == elsewhere)
    #expect(try await collect(response.body) == Array("moved".utf8))
    #expect(script.requests.count == 1)
  }

  @Test func requestHeaderFieldsAndBodyGoOutAsGiven() async throws {
    let marker = try #require(HTTPField.Name("X-Request-Marker"))
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }
    var headerFields = HTTPFields()
    headerFields[.authorization] = "Bearer token"
    headerFields[marker] = "1"

    _ = try await transport.stream(
      target(headerFields: headerFields, method: .post), body: .bytes(Data(#"{"id":1}"#.utf8)),
      options: TransportOptions())

    // Asserted field by field because `StubURLProtocol` leaves its own routing header in the
    // recorded request.
    let call = try #require(script.last)
    #expect(call.request.httpMethod == "POST")
    #expect(call.request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    #expect(call.request.value(forHTTPHeaderField: "X-Request-Marker") == "1")
    #expect(call.body.map(text) == #"{"id":1}"#)
  }

  @Test(arguments: [
    (URLError.Code.badURL, TransportFailureKind.badURL),
    (URLError.Code.unsupportedURL, TransportFailureKind.badURL),
    (URLError.Code.networkConnectionLost, TransportFailureKind.connectivity),
    (URLError.Code.notConnectedToInternet, TransportFailureKind.connectivity),
    (URLError.Code.timedOut, TransportFailureKind.timedOut),
    (URLError.Code.cannotFindHost, TransportFailureKind.other),
    (URLError.Code.secureConnectionFailed, TransportFailureKind.other),
  ])
  func eachURLErrorCodeMapsToItsKind(code: URLError.Code, expected: TransportFailureKind)
    async throws
  {
    let script = StubURLProtocol.Script(answers: [.failure(code: code, failingURL: nil)])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let error = try #require(await streamFailure(sending: target(), through: transport))

    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == expected)
    #expect((underlying as? URLSessionTransportFailure)?.code == code)
    #expect(script.requests.count == 1)
  }

  @Test func aCancelledRequestIsTheCancellationCaseAndNotAKind() async throws {
    let script = StubURLProtocol.Script(answers: [.failure(code: .cancelled, failingURL: nil)])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let error = try #require(await streamFailure(sending: target(), through: transport))

    #expect(isCancelled(error))
    #expect(error.underlying == nil)
    #expect(script.requests.count == 1)
  }

  @Test func aCallerCancelledBeforeSendingLeavesWithCancelled() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data("hello".utf8), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    // A task added to an already-cancelled group starts cancelled, which is deterministic where
    // racing a `cancel()` fired alongside it is not. Whether the request is refused on the call or on
    // the first byte read is the loading system's to decide.
    let outcome = await withTaskGroup(of: TransportError?.self) { group in
      group.cancelAll()
      group.addTask {
        do throws(TransportError) {
          let response = try await transport.stream(
            target(), body: .none, options: TransportOptions())
          _ = try await collect(response.body)
          return nil
        } catch {
          return error
        }
      }
      return await group.next() ?? nil
    }

    #expect(isCancelled(try #require(outcome)))
    #expect(script.requests.count <= 1)
  }

  @Test func aRequestWithNoURLToSendToIsABadURL() async throws {
    let script = StubURLProtocol.Script()
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }
    // No scheme and no authority, so no URL can be built from it and nothing is sent.
    let unsendable = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/v1/things")

    let error = try #require(await streamFailure(sending: unsendable, through: transport))

    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .badURL)
    #expect(underlying == nil)
    #expect(script.requests.isEmpty)
  }

  @Test func aResponseThatIsNotHTTPNamesWhatArrivedInstead() async throws {
    let (session, transport) = makeTransport(answeredBy: NonHTTPURLProtocol.self)
    defer { session.finishTasksAndInvalidate() }

    let error = try #require(await streamFailure(sending: target(), through: transport))

    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .other)
    let unreadable = try #require(underlying as? URLSessionResponseFailure)
    guard case .notHTTP(let responseType, let url) = unreadable else {
      Issue.record("expected a non-HTTP response, got \(unreadable)")
      return
    }
    #expect(responseType.contains("URLResponse"))
    #expect(url?.absoluteString == endpoint)
  }

  @Test func aStatusNoResponseRepresentsIsReportedWithTheStatusItCarried() async throws {
    let (session, transport) = makeTransport(answeredBy: UnrepresentableStatusURLProtocol.self)
    defer { session.finishTasksAndInvalidate() }

    let error = try #require(await streamFailure(sending: target(), through: transport))

    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .other)
    let unreadable = try #require(underlying as? URLSessionResponseFailure)
    guard case .unrepresentableStatus(let code, let url) = unreadable else {
      Issue.record("expected an unrepresentable status, got \(unreadable)")
      return
    }
    #expect(code == UnrepresentableStatusURLProtocol.status)
    #expect(url?.absoluteString == endpoint)
  }

  @Test("Cancelling the reader before the response arrives throws cancelled")
  func cancellingTheReaderBeforeTheResponseArrivesThrowsCancelled() async throws {
    let (session, transport) = makeTransport(answeredBy: NeverAnsweringURLProtocol.self)
    defer { session.invalidateAndCancel() }

    let call = Task { await streamFailure(sending: target(), through: transport) }
    await NeverAnsweringURLProtocol.started.wait(forCount: 1)
    call.cancel()
    let error = try #require(await call.value)

    #expect(isCancelled(error))
  }

  @Test("Twenty concurrent streams each receive their own bytes")
  func twentyConcurrentStreamsEachReceiveTheirOwnBytes() async throws {
    let script = StubURLProtocol.Script()
    // Each request names its own body in its query, and the handler echoes it, so a body delivered
    // to the wrong reader reads as the wrong number.
    script.setHandler(forPath: "/v1/things") { request in
      .response(body: Data((request.url?.query() ?? "").utf8), headers: [:], status: 200)
    }
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    let received = await withTaskGroup(of: (Int, Result<String, TransportError>).self) { group in
      for number in 1...20 {
        group.addTask {
          do throws(TransportError) {
            let response = try await transport.stream(
              target(path: "/v1/things?n=\(number)"), body: .none, options: TransportOptions())
            return (number, .success(text(Data(try await collect(response.body)))))
          } catch {
            return (number, .failure(error))
          }
        }
      }
      var bodies: [Int: Result<String, TransportError>] = [:]
      for await (number, body) in group {
        bodies[number] = body
      }
      return bodies
    }

    for number in 1...20 {
      #expect(try #require(received[number]).get() == "n=\(number)")
    }
    #expect(script.requests.count == 20)
  }
}

/// One call the delegate's buffer made on its control.
private enum Call: Equatable {
  case cancel
  case resume
  case suspend
}

/// A control that records every call in the order it was made and decides nothing.
private final class CountingControl: FlowControl {
  private let log = Mutex<[Call]>([])

  var calls: [Call] {
    log.withLock { $0 }
  }

  func cancel() {
    log.withLock { $0.append(.cancel) }
  }

  func resume() {
    log.withLock { $0.append(.resume) }
  }

  func suspend() {
    log.withLock { $0.append(.suspend) }
  }
}

/// Asserts the calls a control has recorded so far, reporting a mismatch at the calling test.
private func expectCalls(
  _ control: CountingControl, _ expected: [Call],
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(control.calls == expected, sourceLocation: sourceLocation)
}

/// The buffered byte count above which the delegate suspends its control: the documented default,
/// 512 KiB. It resumes at or below the documented 128 KiB, which an empty buffer is.
private let highWatermark = 512 * 1024

/// Waits until the task reports one of `states`, through key-value observation on `state`, and
/// returns the state observed.
///
/// `resume()`, `suspend()`, and `cancel()` settle the task's state on the session's own queue, not
/// on the caller's, so a read straight after the call can see the state before the transition. The
/// observation fires for the current state first, so a task already there returns at once, and the
/// continuation is resumed exactly once however many changes follow.
private func settle(
  _ task: URLSessionTask, in states: Set<URLSessionTask.State>
) async -> URLSessionTask.State {
  let resumed = Mutex(false)
  var observation: NSKeyValueObservation?
  let observed = await withCheckedContinuation {
    (continuation: CheckedContinuation<URLSessionTask.State, Never>) in
    observation = task.observe(\.state, options: [.initial, .new]) { task, _ in
      let state = task.state
      guard states.contains(state) else { return }
      let first = resumed.withLock { flag -> Bool in
        if flag { return false }
        flag = true
        return true
      }
      if first { continuation.resume(returning: state) }
    }
  }
  observation?.invalidate()
  return observed
}

/// A session over `IdleURLProtocol` and a task of it, not yet resumed, so the delegate callbacks a
/// test makes by hand have a task to name and a task the test resumes loads nothing.
private func makeIdleTask() -> (URLSession, URLSessionDataTask) {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [IdleURLProtocol.self]
  let session = URLSession(configuration: configuration)
  return (session, session.dataTask(with: URLRequest(url: endpointURL)))
}

/// What `delegate` hands the loading system for a `302` to `elsewhere`: the request to follow, or
/// `nil` to refuse. The delegate is driven by hand, since no `URLProtocol` makes the loading
/// system ask.
private func redirectAnswer(
  of delegate: any URLSessionTaskDelegate, session: URLSession, task: URLSessionTask
) async throws -> URLRequest? {
  let response = try #require(
    HTTPURLResponse(
      url: endpointURL, statusCode: 302, httpVersion: "HTTP/1.1",
      headerFields: ["Location": elsewhere]))
  let next = URLRequest(url: URL.fixture("https://example.com/v1/elsewhere"))
  return await withCheckedContinuation { continuation in
    delegate.urlSession?(
      session, task: task, willPerformHTTPRedirection: response, newRequest: next
    ) { continuation.resume(returning: $0) }
  }
}

/// The delegate driven by hand, one callback at a time, since no `URLProtocol` can deliver a body
/// a piece at a time. The calls the delegate makes on its control are asserted through a recording
/// conformer, and what those calls do to a task is asserted on the task control itself.
@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct StreamingTaskDelegateTests {
  @Test("A body delivered in three loads arrives as three chunks in order")
  func aBodyDeliveredInThreeLoadsArrivesAsThreeChunksInOrder() async throws {
    let delegate = StreamingTaskDelegate(control: CountingControl())
    let (session, task) = makeIdleTask()
    defer { session.invalidateAndCancel() }
    let response = try #require(okResponse(for: URLRequest(url: endpointURL)))

    delegate.urlSession(session, dataTask: task, didReceive: response) { _ in }
    for load in ["one", "two", "three"] {
      delegate.urlSession(session, dataTask: task, didReceive: Data(load.utf8))
    }
    delegate.urlSession(session, task: task, didCompleteWithError: nil)

    #expect(try await delegate.response().status.code == 200)
    let (received, failure) = await drain(delegate.makeBody())
    #expect(received.map(text) == ["one", "two", "three"])
    #expect(failure == nil)
  }

  @Test("An error after the response arrives reaches the reader as a transport failure")
  func anErrorAfterTheResponseArrivesReachesTheReaderAsATransportFailure() async throws {
    let delegate = StreamingTaskDelegate(control: CountingControl())
    let (session, task) = makeIdleTask()
    defer { session.invalidateAndCancel() }
    let response = try #require(okResponse(for: URLRequest(url: endpointURL)))

    delegate.urlSession(session, dataTask: task, didReceive: response) { _ in }
    delegate.urlSession(session, dataTask: task, didReceive: Data("partial".utf8))
    delegate.urlSession(
      session, task: task, didCompleteWithError: URLError(.networkConnectionLost))

    #expect(try await delegate.response().status.code == 200)
    let (received, failure) = await drain(delegate.makeBody())
    #expect(received.map(text) == ["partial"])
    let error = try #require(failure)
    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .connectivity)
    #expect((underlying as? URLSessionTransportFailure)?.code == .networkConnectionLost)
  }

  @Test("A completion with no error and no response fails the response with nothing behind it")
  func aCompletionWithNoErrorAndNoResponseFailsTheResponseWithNothingBehindIt() async throws {
    let delegate = StreamingTaskDelegate(control: CountingControl())
    let (session, task) = makeIdleTask()
    defer { session.invalidateAndCancel() }

    delegate.urlSession(session, task: task, didCompleteWithError: nil)

    let error: TransportError
    do throws(TransportError) {
      _ = try await delegate.response()
      Issue.record("expected the response to fail")
      return
    } catch let caught {
      error = caught
    }
    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .other)
    #expect(underlying == nil)
  }

  @Test("The task control suspends, resumes, and cancels the task it holds")
  func theTaskControlSuspendsResumesAndCancelsTheTaskItHolds() async throws {
    let (session, task) = makeIdleTask()
    defer { session.invalidateAndCancel() }
    let control = TaskControl(task: task)
    #expect(task.state == .suspended)

    control.resume()
    let resumed = await settle(task, in: [.running])
    #expect(resumed == .running)

    control.suspend()
    let suspended = await settle(task, in: [.suspended])
    #expect(suspended == .suspended)

    control.resume()
    let resumedAgain = await settle(task, in: [.running])
    #expect(resumedAgain == .running)

    // `cancel()` moves the task to `canceling`; the loading system finishes it from there, so
    // either state is the task cancelled.
    control.cancel()
    let cancelled = await settle(task, in: [.canceling, .completed])
    #expect(cancelled == .canceling || cancelled == .completed)

    // A late resume, the one a buffer sends once its reader drains, leaves a cancelled task alone.
    control.resume()
    let afterLateResume = await settle(task, in: [.canceling, .completed])
    #expect(afterLateResume == .canceling || afterLateResume == .completed)
  }

  @Test("The delegate opens a fresh stream on the body file for each replay, and none otherwise")
  func theDelegateOpensAFreshStreamOnTheBodyFileForEachReplay() async throws {
    let file = try temporaryFile(Data("recording bytes".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    let (session, task) = makeIdleTask()
    defer { session.invalidateAndCancel() }
    // Each handed stream is opened once recorded, so a stream handed twice would arrive open the
    // second time, and a fresh one arrives not yet opened.
    let statuses = Mutex<[Stream.Status?]>([])
    let recordAndOpen: @Sendable (InputStream?) -> Void = { stream in
      statuses.withLock { $0.append(stream?.streamStatus) }
      stream?.open()
    }

    let fileDelegate = StreamingTaskDelegate(bodyFile: file, control: CountingControl())
    fileDelegate.urlSession(session, task: task, needNewBodyStream: recordAndOpen)
    fileDelegate.urlSession(session, task: task, needNewBodyStream: recordAndOpen)
    let bytesDelegate = StreamingTaskDelegate(control: CountingControl())
    bytesDelegate.urlSession(session, task: task, needNewBodyStream: recordAndOpen)

    #expect(statuses.withLock { $0 } == [.notOpen, .notOpen, nil])
  }

  @Test("The delegate suspends its control above the high watermark and resumes it once drained")
  func theDelegateSuspendsItsControlAboveTheHighWatermarkAndResumesItOnceDrained() async throws {
    let control = CountingControl()
    let delegate = StreamingTaskDelegate(control: control)
    let (session, task) = makeIdleTask()
    defer { session.invalidateAndCancel() }
    let response = try #require(okResponse(for: URLRequest(url: endpointURL)))

    delegate.urlSession(session, dataTask: task, didReceive: response) { _ in }
    #expect(try await delegate.response().status.code == 200)
    var iterator: StreamedBody.Iterator? = delegate.makeBody().makeAsyncIterator()

    // One chunk past the high watermark, delivered before any read.
    delegate.urlSession(session, dataTask: task, didReceive: Data(count: highWatermark + 1))
    expectCalls(control, [.suspend])

    // Taking it drains the buffer to nothing, which is at or below the low watermark.
    var current = try #require(iterator)
    #expect(try await current.next()?.count == highWatermark + 1)
    iterator = current
    expectCalls(control, [.suspend, .resume])

    delegate.urlSession(session, task: task, didCompleteWithError: nil)
    current = try #require(iterator)
    #expect(try await current.next() == nil)
    iterator = current
    expectCalls(control, [.suspend, .resume])
  }

  @Test("Dropping the body cancels the control while the task is still running")
  func droppingTheBodyCancelsTheControlWhileTheTaskIsStillRunning() async throws {
    let control = CountingControl()
    let delegate = StreamingTaskDelegate(control: control)
    let (session, task) = makeIdleTask()
    defer { session.invalidateAndCancel() }
    let response = try #require(okResponse(for: URLRequest(url: endpointURL)))

    delegate.urlSession(session, dataTask: task, didReceive: response) { _ in }
    _ = try await delegate.response()
    var body: StreamedBody? = delegate.makeBody()
    expectCalls(control, [])

    body = nil

    expectCalls(control, [.cancel])
    _ = body
  }

  @Test("The streaming delegate refuses a redirect, so the 3xx is the task's response")
  func theStreamingDelegateRefusesARedirect() async throws {
    let (session, task) = makeIdleTask()
    defer { session.invalidateAndCancel() }
    let delegate = StreamingTaskDelegate(control: CountingControl())

    #expect(try await redirectAnswer(of: delegate, session: session, task: task) == nil)
  }

  @Test("The redirect-refusing delegate answers a redirect with nil")
  func theRefusingDelegateRefusesARedirect() async throws {
    let (session, task) = makeIdleTask()
    defer { session.invalidateAndCancel() }

    #expect(
      try await redirectAnswer(of: RedirectRefusingDelegate(), session: session, task: task) == nil)
  }

  @Test("Dropping the body of a finished task cancels nothing")
  func droppingTheBodyOfAFinishedTaskCancelsNothing() async throws {
    let control = CountingControl()
    let delegate = StreamingTaskDelegate(control: control)
    let (session, task) = makeIdleTask()
    defer { session.invalidateAndCancel() }
    let response = try #require(okResponse(for: URLRequest(url: endpointURL)))

    delegate.urlSession(session, dataTask: task, didReceive: response) { _ in }
    _ = try await delegate.response()
    delegate.urlSession(session, task: task, didCompleteWithError: nil)
    var body: StreamedBody? = delegate.makeBody()
    expectCalls(control, [])

    body = nil

    expectCalls(control, [])
    _ = body
  }
}

/// What one path put on the wire, as `StubURLProtocol` recorded it, with the stub's own routing
/// field left out so two requests compare on what the transport set.
private struct WireRequest: Equatable {
  let body: Data?
  let cachePolicy: URLRequest.CachePolicy
  let headerFields: [String: String]
  let method: String?
  let url: URL?

  init(_ call: StubURLProtocol.Call) {
    body = call.body
    cachePolicy = call.request.cachePolicy
    headerFields = (call.request.allHTTPHeaderFields ?? [:]).filter { field in
      field.key.caseInsensitiveCompare(StubURLProtocol.tokenHeaderField) != .orderedSame
    }
    method = call.request.httpMethod
    url = call.request.url
  }
}

/// A file holding `contents`, in the temporary directory, for the transport to read from.
private func temporaryFile(_ contents: Data) throws -> URL {
  let url = missingFile()
  try contents.write(to: url)
  return url
}

/// A file URL in the temporary directory that names nothing on disk.
private func missingFile() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

/// Sends `body` through both paths, each answered by its own script, and returns what each put on
/// the wire.
private func bothPaths(
  _ body: TransportBody, headerFields: HTTPFields, method: HTTPRequest.Method
) async throws -> (sent: WireRequest, streamed: WireRequest) {
  let script = StubURLProtocol.Script(answers: [
    .response(body: Data(), headers: [:], status: 200),
    .response(body: Data(), headers: [:], status: 200),
  ])
  let (session, transport) = makeTransport(script)
  defer { session.finishTasksAndInvalidate() }
  let request = target(headerFields: headerFields, method: method)
  let options = TransportOptions(cachePolicy: .revalidate)

  _ = try await transport.send(request, body: body, options: options)
  let sent = try #require(script.last)
  _ = try await transport.stream(request, body: body, options: options)
  let streamed = try #require(script.last)
  return (WireRequest(sent), WireRequest(streamed))
}

/// A `URLProtocol` that redirects `/v1/start` to `/v1/end` through the loading system itself, the
/// way a network load does, so the task's delegate is asked whether to follow. `StubURLProtocol`
/// delivers a `3xx` as a plain response, which the loading system never follows on its own, so it
/// cannot show that the refusal is doing anything.
///
/// The `3xx` is delivered after the redirect is announced, because a delegate that refuses leaves
/// this load to finish with the response the client should see; a load the loading system moved
/// on from ignores what follows.
private final class RedirectingURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let client, let url = request.url else { return }
    if url.path == "/v1/start" {
      let next = URL.fixture("https://example.com/v1/end")
      guard
        let response = HTTPURLResponse(
          url: url, statusCode: 302, httpVersion: "HTTP/1.1",
          headerFields: ["Location": next.absoluteString])
      else { return }
      client.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client.urlProtocol(self, didLoad: Data("moved".utf8))
      client.urlProtocolDidFinishLoading(self)
    } else {
      guard let response = okResponse(for: request) else { return }
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client.urlProtocol(self, didLoad: Data("arrived".utf8))
      client.urlProtocolDidFinishLoading(self)
    }
  }

  /// Does nothing: the answer is delivered before ``startLoading()`` returns, so nothing is in flight.
  override func stopLoading() {}
}

/// The redirect refusal against a loader that would follow, with a control leg proving it would.
@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct URLSessionTransportRedirectTests {
  @Test("A session with no delegate follows the protocol's redirect, so the refusals below do work")
  func aBareSessionFollows() async throws {
    let (session, _) = makeTransport(answeredBy: RedirectingURLProtocol.self)
    defer { session.finishTasksAndInvalidate() }

    let (data, response) = try await session.data(
      from: URL.fixture("https://example.com/v1/start"))

    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(text(data) == "arrived")
  }

  @Test("send returns the 3xx a loader would otherwise follow")
  func sendReturnsThe3xx() async throws {
    let (session, transport) = makeTransport(answeredBy: RedirectingURLProtocol.self)
    defer { session.finishTasksAndInvalidate() }

    let response = try await transport.send(
      target(path: "/v1/start"), body: .none, options: TransportOptions())

    #expect(response.status.code == 302)
    #expect(response.headers[.location] == "https://example.com/v1/end")
    #expect(text(response.body) == "moved")
  }

  @Test("stream returns the 3xx a loader would otherwise follow")
  func streamReturnsThe3xx() async throws {
    let (session, transport) = makeTransport(answeredBy: RedirectingURLProtocol.self)
    defer { session.finishTasksAndInvalidate() }

    let response = try await transport.stream(
      target(path: "/v1/start"), body: .none, options: TransportOptions())

    #expect(response.status.code == 302)
    #expect(response.headers[.location] == "https://example.com/v1/end")
    #expect(try await collect(response.body) == Array("moved".utf8))
  }
}

/// The body kinds and the options, as each reaches the `URLRequest` the session sends.
@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct URLSessionTransportBoundaryTests {
  @Test("A file body is sent from the file without reading it into the request")
  func aFileBodyIsSentFromTheFileWithoutReadingItIntoTheRequest() async throws {
    let contents = Data("recording bytes".utf8)
    let file = try temporaryFile(contents)
    defer { try? FileManager.default.removeItem(at: file) }
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    _ = try await transport.send(
      target(method: .put), body: .file(file), options: TransportOptions())

    let call = try #require(script.last)
    #expect(call.request.httpBody == nil)
    #expect(call.body == contents)
    #expect(call.request.value(forHTTPHeaderField: "Content-Length") == "\(contents.count)")
  }

  @Test("A streamed file body is opened as a stream on the file, never read into the request")
  func aStreamedFileBodyIsOpenedAsAStreamOnTheFile() async throws {
    let contents = Data("recording bytes".utf8)
    let file = try temporaryFile(contents)
    defer { try? FileManager.default.removeItem(at: file) }
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    _ = try await transport.stream(
      target(method: .put), body: .file(file), options: TransportOptions())

    let call = try #require(script.last)
    #expect(call.request.httpBody == nil)
    #expect(call.body == contents)
    #expect(call.request.value(forHTTPHeaderField: "Content-Length") == "\(contents.count)")
  }

  @Test("A streamed file body whose file cannot be read is a bad URL")
  func aStreamedFileBodyWhoseFileCannotBeReadIsABadURL() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    // A file URL that names nothing: the stream opens on the path, and the size is what cannot
    // be read.
    let error = try #require(
      await streamFailure(
        sending: target(method: .put), body: .file(missingFile()), through: transport))

    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .badURL)
    #expect(underlying == nil)
    #expect(script.requests.isEmpty)
  }

  @Test("send hands an unreadable file to the session without a check of its own")
  func sendHandsAnUnreadableFileToTheSessionWithoutACheckOfItsOwn() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    // The session reads the file, not the transport. Loaded through a `URLProtocol` nothing reads
    // it at all, so the request reaches the stub with an empty body; a network load is where the
    // session reports its `URLError`, which the mapping carries as `other`.
    _ = try await transport.send(
      target(method: .put), body: .file(missingFile()), options: TransportOptions())

    let call = try #require(script.last)
    #expect(call.request.httpBody == nil)
    #expect((call.body ?? Data()).isEmpty)
  }

  @Test(
    "Each cache policy maps onto the matching URLRequest policy",
    arguments: [
      (CachePolicy.cacheElseLoad, URLRequest.CachePolicy.returnCacheDataElseLoad),
      (CachePolicy.ignoreCache, URLRequest.CachePolicy.reloadIgnoringLocalCacheData),
      (CachePolicy.revalidate, URLRequest.CachePolicy.reloadRevalidatingCacheData),
      (CachePolicy.standard, URLRequest.CachePolicy.useProtocolCachePolicy),
    ])
  func eachCachePolicyMapsOntoTheMatchingURLRequestPolicy(
    policy: CachePolicy, expected: URLRequest.CachePolicy
  ) async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    _ = try await transport.send(
      target(), body: .none, options: TransportOptions(cachePolicy: policy))

    let call = try #require(script.last)
    #expect(call.request.cachePolicy == expected)
  }

  @Test(
    "A cache-only request with nothing cached fails as resourceUnavailable without reaching the wire"
  )
  func aCacheOnlyRequestWithNothingCachedFailsWithoutReachingTheWire() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    // `returnCacheDataDontLoad` is answered by the loading system before any `URLProtocol` is
    // consulted, so the refusal is what proves the policy reached the request: every other policy
    // reaches the stub.
    let error = try #require(
      await failure(
        sending: target(), options: TransportOptions(cachePolicy: .cacheOnly), through: transport))

    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .other)
    #expect((underlying as? URLSessionTransportFailure)?.code == .resourceUnavailable)
    #expect(script.requests.isEmpty)
  }

  @Test("A request with no cache policy leaves the URLRequest default")
  func aRequestWithNoCachePolicyLeavesTheURLRequestDefault() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data(), headers: [:], status: 200)
    ])
    let (session, transport) = makeTransport(script)
    defer { session.finishTasksAndInvalidate() }

    _ = try await transport.send(target(), body: .none, options: TransportOptions())

    let call = try #require(script.last)
    #expect(call.request.cachePolicy == .useProtocolCachePolicy)
  }

  @Test("send and stream present the same URLRequest for a bytes body")
  func sendAndStreamPresentTheSameURLRequestForABytesBody() async throws {
    let marker = try #require(HTTPField.Name("X-Request-Marker"))
    let payload = Data(#"{"id":1}"#.utf8)

    let (sent, streamed) = try await bothPaths(
      .bytes(payload), headerFields: [marker: "1"], method: .post)

    #expect(sent == streamed)
    #expect(sent.body == payload)
    #expect(sent.method == "POST")
    #expect(sent.url == endpointURL)
    #expect(sent.headerFields["X-Request-Marker"] == "1")
    #expect(sent.cachePolicy == .reloadRevalidatingCacheData)
  }

  @Test("send and stream present the same URLRequest for a file body")
  func sendAndStreamPresentTheSameURLRequestForAFileBody() async throws {
    let marker = try #require(HTTPField.Name("X-Request-Marker"))
    let contents = Data("recording bytes".utf8)
    let file = try temporaryFile(contents)
    defer { try? FileManager.default.removeItem(at: file) }

    // The content type is set as the client always sets it for a file body; without one the
    // buffered path alone would add a default.
    let (sent, streamed) = try await bothPaths(
      .file(file), headerFields: [.contentType: "video/mp4", marker: "1"], method: .put)

    #expect(sent == streamed)
    #expect(sent.body == contents)
    #expect(sent.method == "PUT")
    #expect(sent.url == endpointURL)
    #expect(sent.headerFields["Content-Length"] == "\(contents.count)")
    #expect(sent.headerFields["Content-Type"] == "video/mp4")
    #expect(sent.headerFields["X-Request-Marker"] == "1")
    #expect(sent.cachePolicy == .reloadRevalidatingCacheData)
  }

  @Test("send and stream present the same URLRequest for no body")
  func sendAndStreamPresentTheSameURLRequestForNoBody() async throws {
    let marker = try #require(HTTPField.Name("X-Request-Marker"))

    let (sent, streamed) = try await bothPaths(.none, headerFields: [marker: "1"], method: .get)

    #expect(sent == streamed)
    #expect(sent.body == nil)
    #expect(sent.method == "GET")
    #expect(sent.url == endpointURL)
    #expect(sent.headerFields["X-Request-Marker"] == "1")
    #expect(sent.cachePolicy == .reloadRevalidatingCacheData)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct HTTPClientURLSessionTests {
  @Test("The URLSession convenience initializer builds a client over the given session")
  func theConvenienceInitializerBuildsAClientOverTheGivenSession() async throws {
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data("hello".utf8), headers: [:], status: 200)
    ])
    let session = URLSession(configuration: script.makeSessionConfiguration())
    defer { session.finishTasksAndInvalidate() }
    let client = HTTPClient(baseURL: URL.fixture("https://example.com/v1"), session: session)

    let response = try await client.execute(Request(path: "/things"))

    #expect(client.transport is URLSessionTransport)
    #expect(text(response.body) == "hello")
    #expect(script.requests.map { $0.request.url?.absoluteString } == [endpoint])
  }
}

#endif
