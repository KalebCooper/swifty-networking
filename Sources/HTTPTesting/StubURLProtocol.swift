// `URLProtocol` and the URL loading system it plugs into exist only on Apple platforms, so the
// whole stub compiles away elsewhere.
#if canImport(Darwin)

import Foundation
import Synchronization

/// A `URLProtocol` that answers a `URLSession` from what a test scripted, with no network involved.
///
/// The URL loading system instantiates a `URLProtocol` subclass itself, so the answers live on a
/// ``Script`` that the test creates and holds. The configuration a script hands out carries a token
/// identifying it, and every request made through a session built from that configuration is routed
/// back to that script alone. Two scripts alive at once, such as two tests running in parallel in
/// one process, cannot see each other's answers, so a suite needs no serialization to stay
/// deterministic.
///
/// ```swift
/// @Test func sendsTheRequestAndReadsTheResponse() async throws {
///   let script = StubURLProtocol.Script(answers: [
///     .response(
///       body: Data(#"{"id":"42"}"#.utf8),
///       headers: ["Content-Type": "application/json"],
///       status: 200)
///   ])
///   let session = URLSession(configuration: script.makeSessionConfiguration())
///
///   let url = try #require(URL(string: "https://api.example.com/me"))
///   let (data, response) = try await session.data(for: URLRequest(url: url))
///
///   #expect((response as? HTTPURLResponse)?.statusCode == 200)
///   #expect(data == Data(#"{"id":"42"}"#.utf8))
///   #expect(script.last?.request.httpMethod == "GET")
/// }
/// ```
///
/// Hold the script for as long as the session under test runs. When a script is released its token
/// stops resolving, and any session still holding its configuration fails with
/// ``StubURLProtocolFailure/noCannedResponse``.
///
/// ## Live Requests
///
/// ``canInit(with:)`` answers `true` only for a request carrying a script token. A request without
/// one belongs to something else, such as a session a test built by hand or code that reached the
/// network by mistake, and the loading system takes it to the real network, where it succeeds or
/// fails visibly instead of being answered by a stub nobody pointed at it.
public final class StubURLProtocol: URLProtocol {
  /// What the stub does with one request.
  ///
  /// A failure carries a `URLError.Code` and the stub builds the `URLError` when it delivers it,
  /// because an error's `userInfo` is untyped and a built error is not `Sendable`. Give
  /// `failingURL` to script the error shape whose description echoes a URL.
  ///
  /// There is no delay: time in a test comes from the `Clock` injected into the code under test,
  /// not from the stub.
  public enum Answer: Hashable, Sendable {
    /// The task fails with a `URLError` of this code, carrying `failingURL` when one is given.
    case failure(code: URLError.Code, failingURL: URL?)

    /// The task receives this status and these header fields, then this body, then finishes.
    case response(body: Data, headers: [String: String], status: Int)
  }

  /// One request as the URL loading system delivered it to the stub.
  public struct Call: Hashable, Sendable {
    /// The body the request carried, or `nil` when it carried none.
    ///
    /// `URLSession` turns a request body into a stream before a `URLProtocol` sees it, so this is
    /// the body read back out of that stream. Assert on this property; `request.httpBody` is
    /// `nil` by the time the request arrives here.
    public let body: Data?

    /// The request, including the header field carrying the script's token.
    ///
    /// The token field is left in place, so what a test reads is exactly what the loading system
    /// saw. Read the fields you care about with `value(forHTTPHeaderField:)` instead of comparing
    /// the whole dictionary.
    public let request: URLRequest

    /// Creates a call, for comparing a recorded one against an expected value.
    ///
    /// - Parameters:
    ///   - body: The request body, or `nil`.
    ///   - request: The request.
    public init(body: Data?, request: URLRequest) {
      self.body = body
      self.request = request
    }
  }

  private typealias Handler = @Sendable (URLRequest) -> Answer

  /// What one request resolved to under the lock. A handler is carried out of the critical section
  /// before it runs, because it is test-supplied code that may read the log or seed another answer.
  private enum Resolved {
    case answer(Answer)
    case handler(Handler)
    case unscripted
  }

  private struct State {
    var handlers: [String: Handler] = [:]
    var queue: [Answer] = []
    var requests: [Call] = []
  }

  /// The answers a test scripted for one `URLSession`, and the log of what that session asked for.
  ///
  /// Seed it in either of two ways, the same two ``MockTransport`` offers, and each request is
  /// served by exactly one of them:
  ///
  /// - A handler registered with ``setHandler(forPath:handler:)`` answers every request whose path,
  ///   without its query string, matches its key, however many arrive, so one registration serves a
  ///   burst of concurrent callers.
  /// - The queue seeded through ``init(answers:)`` and ``enqueue(_:)`` answers in first-in,
  ///   first-out order, one answer per request, which scripts a sequence such as a `401` followed
  ///   by a `200`.
  ///
  /// A handler registered for the request's path answers that request, whatever query string it
  /// carries, and every other request falls to the queue. A request with no URL matches no handler
  /// and always falls to the queue.
  ///
  /// A request that matches no handler and finds the queue empty fails with
  /// ``StubURLProtocolFailure/noCannedResponse``, so a test that scripted too little fails as a
  /// test instead of reaching the network. The request is recorded either way: ``requests`` holds
  /// every request in the order it arrived, including one that found nothing scripted, so its count
  /// is the number of requests made, not the number answered. ``reset()`` returns the script to its
  /// freshly constructed state: no queued answers, no handlers, no recorded requests.
  public final class Script: Sendable {
    private let token = UUID().uuidString

    /// Creates a script whose queue holds `answers`, to be delivered in order.
    ///
    /// - Parameter answers: The scripted answers, first to be returned first; empty by default, for
    ///   a script driven entirely by handlers.
    public init(answers: [Answer] = []) {
      StubURLProtocol.scripts.withLock { $0[token] = State(queue: answers) }
    }

    deinit {
      StubURLProtocol.scripts.withLock { $0[token] = nil }
    }

    /// The most recent request, or `nil` before any has arrived.
    public var last: Call? {
      StubURLProtocol.scripts.withLock { $0[token]?.requests.last }
    }

    /// Every request so far, in the order the stub received them.
    public var requests: [Call] {
      StubURLProtocol.scripts.withLock { $0[token]?.requests ?? [] }
    }

    /// Adds one answer to the back of the queue.
    ///
    /// - Parameter answer: The answer to deliver once every answer already queued has been.
    public func enqueue(_ answer: Answer) {
      StubURLProtocol.scripts.withLock { $0[token]?.queue.append(answer) }
    }

    /// Builds a session configuration whose requests this script answers.
    ///
    /// The configuration is ephemeral, with no cache and no cookie or credential storage on disk,
    /// so nothing a test sends outlives it. It carries ``StubURLProtocol/tokenHeaderField`` set to
    /// this script's token, which is both how a request finds its way back here and how the stub
    /// tells a scripted request from a live one. Each call builds a fresh configuration, and
    /// several sessions built from one script all answer from it.
    ///
    /// ```swift
    /// let session = URLSession(configuration: script.makeSessionConfiguration())
    /// let transport = URLSessionTransport(session: session)
    /// ```
    ///
    /// - Returns: A configuration to pass to `URLSession(configuration:)`.
    public func makeSessionConfiguration() -> URLSessionConfiguration {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpAdditionalHeaders = [StubURLProtocol.tokenHeaderField: token]
      configuration.protocolClasses = [StubURLProtocol.self]
      return configuration
    }

    /// Returns the script to its freshly constructed state: no queued answers, no handlers, no
    /// recorded requests.
    public func reset() {
      StubURLProtocol.scripts.withLock { $0[token] = State() }
    }

    /// Registers the answer for every request that arrives at `path`, replacing any handler already
    /// registered for it.
    ///
    /// The key is the path without its query string, so a handler registered for `"/me"` answers a
    /// request for `"/me?x=1"` as well as one for `"/me"`. It is compared against the path with
    /// percent-encoding removed, so a key that itself contains a `?` matches only a request whose
    /// path carries that `?` percent-encoded. The handler receives the request as it arrived, so a
    /// handler that varies its answer by query reads the query from the request's URL.
    ///
    /// The handler is synchronous and runs outside the stub's lock, so it may read ``requests`` or
    /// seed further answers. It runs once per matching request, so one registration serves a burst
    /// of concurrent callers.
    ///
    /// - Parameters:
    ///   - path: The request path to match, without a query string, compared against the URL's path
    ///     with percent-encoding removed.
    ///   - handler: The answer for a request at that path.
    public func setHandler(
      forPath path: String,
      handler: @escaping @Sendable (URLRequest) -> Answer
    ) {
      StubURLProtocol.scripts.withLock { $0[token]?.handlers[path] = handler }
    }
  }

  /// The header field carrying the token that routes a request to the script that answers it.
  ///
  /// A test asserting on what was sent can use this name to tell the routing field apart from the
  /// fields the code under test set.
  public static let tokenHeaderField = "X-Swifty-Networking-Stub"

  /// How many bytes are read from a body stream at a time.
  private static let readSize = 4096

  /// An upper bound on reads from one body stream, so a stream that keeps claiming bytes it never
  /// delivers ends the test instead of spinning forever.
  private static let readLimit = 4096

  private static let scripts = Mutex<[String: State]>([:])

  /// Returns a Boolean value that indicates whether this stub handles the request.
  ///
  /// It handles a request carrying ``tokenHeaderField`` and no other, so a request meant for the
  /// network is left to the network.
  ///
  /// - Parameter request: The request the URL loading system is looking for a handler for.
  /// - Returns: `true` when the request carries ``tokenHeaderField``.
  public override class func canInit(with request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: tokenHeaderField) != nil
  }

  /// Returns the request unchanged, so a test asserts on exactly what it sent.
  ///
  /// - Parameter request: The request to canonicalize.
  /// - Returns: The same request.
  public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  /// Records the request, then delivers the answer from the handler registered for its path, or
  /// from the queue.
  ///
  /// The whole answer, response and body and completion, is delivered before this method returns.
  public override func startLoading() {
    guard let client else { return }
    let call = Call(body: Self.capturedBody(of: request), request: request)
    let token = request.value(forHTTPHeaderField: Self.tokenHeaderField)
    let resolved = Self.resolve(call, token: token)

    let answer: Answer
    switch resolved {
    case .answer(let scripted):
      answer = scripted
    case .handler(let handler):
      answer = handler(request)
    case .unscripted:
      client.urlProtocol(self, didFailWithError: StubURLProtocolFailure.noCannedResponse)
      return
    }

    switch answer {
    case .failure(let code, let failingURL):
      client.urlProtocol(self, didFailWithError: Self.urlError(code: code, failingURL: failingURL))
    case .response(let body, let headers, let status):
      guard let url = request.url,
        let response = HTTPURLResponse(
          url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
      else {
        client.urlProtocol(self, didFailWithError: StubURLProtocolFailure.invalidResponse)
        return
      }
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !body.isEmpty {
        client.urlProtocol(self, didLoad: body)
      }
      client.urlProtocolDidFinishLoading(self)
    }
  }

  /// Does nothing.
  ///
  /// ``startLoading()`` delivers its entire answer before it returns, so nothing is in flight by
  /// the time the URL loading system asks to stop, and this method is safe to call any number of
  /// times.
  public override func stopLoading() {}

  /// Reads back the body the request carried, from wherever the loading system left it.
  private static func capturedBody(of request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    return drain(stream)
  }

  /// Reads a body stream to its end.
  ///
  /// `InputStream` reads into a raw pointer and nothing else, which is why the read below is
  /// `unsafe`. The buffer is a local this function owns, it is fully initialized before the read,
  /// and neither it nor a pointer to it outlives the call.
  private static func drain(_ stream: InputStream) -> Data {
    var buffer = [UInt8](repeating: 0, count: readSize)
    var data = Data()
    stream.open()
    defer { stream.close() }
    for _ in 0..<readLimit {
      guard stream.hasBytesAvailable else { break }
      let count = unsafe stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(contentsOf: buffer[..<count])
    }
    return data
  }

  /// Logs the request against its script and decides what answers it, in one critical section so
  /// concurrent requests consume each queued answer exactly once and no log entry is lost.
  private static func resolve(_ call: Call, token: String?) -> Resolved {
    guard let token else { return .unscripted }
    return scripts.withLock { table -> Resolved in
      guard var state = table[token] else { return .unscripted }
      state.requests.append(call)

      let resolved: Resolved
      if let path = call.request.url?.path(percentEncoded: false),
        let handler = state.handlers[path]
      {
        resolved = .handler(handler)
      } else if state.queue.isEmpty {
        resolved = .unscripted
      } else {
        resolved = .answer(state.queue.removeFirst())
      }

      table[token] = state
      return resolved
    }
  }

  /// Builds the `URLError` a scripted failure delivers, attaching the failing URL under the key
  /// `URLError.failingURL` reads it from.
  private static func urlError(code: URLError.Code, failingURL: URL?) -> URLError {
    guard let failingURL else { return URLError(code) }
    return URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: failingURL])
  }
}

#endif
