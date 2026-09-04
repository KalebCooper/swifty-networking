// `Data` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPCore
import HTTPTypes
import Synchronization

/// A ``/HTTPCore/Transport`` that answers from what a test seeded and records every call it
/// received.
///
/// Seed it in either of two ways, and each request is served by exactly one of them:
///
/// - A handler registered with ``setHandler(forPath:handler:)`` answers every request whose path,
///   without its query string, matches its key, however many arrive, so one registration serves a
///   burst of concurrent callers.
/// - The queue seeded through ``init(answers:results:)`` and ``enqueue(_:)`` answers in first-in,
///   first-out order, one answer per request, which scripts a sequence such as a `401` followed by
///   a `200`.
///
/// A handler registered for the request's path answers that request, whatever query string it
/// carries, and every other request falls to the queue. A request whose path is `nil` matches no
/// handler and always falls to the queue.
///
/// One seeding serves both surfaces. ``stream(_:body:options:)`` hands the answer's body over as it
/// arrives, and ``/HTTPCore/Transport/send(_:body:options:)``, which this transport takes from the
/// protocol, streams the same answer and drains it into one ``/HTTPCore/Response``. Seed a response
/// where the body whole is all the test cares about, and an ``Answer`` where the chunk boundaries
/// or a failure part-way through the body are the point.
///
/// ```swift
/// struct Profile: Decodable {
///   let id: String
/// }
///
/// @Test func readsTheProfile() async throws {
///   let transport = MockTransport(results: [
///     .success(.ok(json: Fixtures.jsonObject(["id": "42"])))
///   ])
///   let client = HTTPClient(
///     baseURL: URL(string: "https://api.example.com")!,
///     transport: transport
///   )
///
///   let profile: Profile = try await client.execute(Request(path: "/me"))
///
///   #expect(profile.id == "42")
///   #expect(transport.requests.count == 1)
///   #expect(transport.last?.request.path == "/me")
/// }
/// ```
///
/// ## Running Out of Answers
///
/// A request that matches no handler and finds the queue empty fails with
/// ``/HTTPCore/TransportError/transport(kind:underlying:)`` carrying
/// ``MockTransportFailure/noCannedResponse``, so a test that seeded too little fails as a test
/// instead of hanging or receiving a response nobody wrote.
///
/// The call is recorded either way. ``requests`` holds every call in the order it arrived,
/// including the one that found the queue empty, so its count is the number of calls made, not the
/// number answered. A buffered call is one call: it reaches the transport through
/// ``stream(_:body:options:)`` and is recorded there once. ``reset()`` returns the transport to its
/// freshly constructed state: no queued answers, no handlers, no recorded calls.
///
/// ## Streaming a Body
///
/// An ``Answer`` carries the status and the header fields the response arrives with, and a body
/// that can end with a failure, which is how a test scripts a body that fails part-way through.
///
/// ```swift
/// let transport = MockTransport(answers: [
///   .success(MockTransport.Answer(chunks: [Data("data: hi\n\n".utf8)]))
/// ])
/// ```
///
/// Each seeded chunk is delivered as one element of the body, so a test places a chunk boundary
/// exactly where it wants one, inside a line or between two.
///
/// ## Isolation
///
/// One `Mutex` guards the queue, the handler table, and the log, and a call's dequeue and its log
/// entry happen in the same critical section, so concurrent callers consume each seeded answer
/// exactly once and no entry is lost. A handler is carried out of the critical section before it
/// runs. The transport is not an `actor`: ``stream(_:body:options:)`` runs on the caller's actor,
/// which is the isolation a live transport gives the code under test.
public final class MockTransport: Transport, Sendable {
  /// One call as the transport received it.
  public struct Call: Hashable, Sendable {
    /// The body the caller passed; ``/HTTPCore/TransportBody/none`` for a body-less request.
    public let body: TransportBody

    /// The options the caller passed, as the client projected them from the request's own.
    public let options: TransportOptions

    /// The request the caller passed, with whatever header fields the client had applied by then.
    public let request: HTTPRequest

    /// Creates a call, for comparing a recorded one against an expected value.
    ///
    /// - Parameters:
    ///   - body: The request body.
    ///   - options: The transport options.
    ///   - request: The request.
    public init(body: TransportBody, options: TransportOptions, request: HTTPRequest) {
      self.body = body
      self.options = options
      self.request = request
    }
  }

  /// One answer, as a test seeded it: a status, header fields, and a body built for each delivery.
  ///
  /// The body is built on demand rather than held, so one answer serves as many requests as it is
  /// asked to. A handler returns the same answer to every caller in a burst and each of them reads
  /// the body whole, and an answer queued twice is read twice.
  ///
  /// ```swift
  /// let answer = MockTransport.Answer(
  ///   chunks: [Data("data: one\n\n".utf8), Data("data: two\n\n".utf8)],
  ///   headers: [.contentType: "text/event-stream"]
  /// )
  /// ```
  public struct Answer: Sendable {
    /// The response header fields, complete: they arrive ahead of the body.
    public var headers: HTTPFields

    /// Builds the response body for one delivery.
    ///
    /// A sequence is consumed as it is read, so an answer that held one could be read only once and
    /// every caller in a burst after the first would find it empty. Building one per delivery is
    /// what lets a single answer serve them all.
    fileprivate let makeBody: @Sendable () -> StreamedBody

    /// The response status, returned whatever it is.
    public var status: HTTPResponse.Status

    /// Creates an answer that delivers `response` as it stands.
    ///
    /// The status and the header fields are the response's own, and its body arrives as one chunk,
    /// or as no chunk at all where the response carries none, which is what a transport reports for
    /// a response with no data.
    ///
    /// - Parameter response: The response to answer with.
    public init(_ response: Response) {
      self.init(
        body: {
          StreamedBody(
            AsyncStream<Data> { continuation in
              if !response.body.isEmpty { continuation.yield(response.body) }
              continuation.finish()
            })
        },
        headers: response.headers,
        status: response.status)
    }

    /// Creates an answer whose body is a sequence the test builds itself.
    ///
    /// Use it where chunks cannot express what the test needs, such as a body that neither delivers
    /// nor ends for as long as the test holds the continuation feeding it. The closure runs once for
    /// each request the answer serves, so a body built here is built again for the next caller.
    ///
    /// - Parameters:
    ///   - body: Builds the response body, once per delivery.
    ///   - headers: The response header fields; none by default.
    ///   - status: The response status; `.ok` by default.
    public init(
      body: @escaping @Sendable () -> StreamedBody,
      headers: HTTPFields = [:],
      status: HTTPResponse.Status = .ok
    ) {
      self.headers = headers
      self.makeBody = body
      self.status = status
    }

    /// Creates an answer that delivers `chunks` in order, each as one element, and then ends, or
    /// fails.
    ///
    /// Every chunk is delivered before `failure` is reported, so a body that fails part-way through
    /// is scripted by seeding the chunks that arrive first and the failure that ends them. A chunk
    /// is handed over exactly as given, an empty one included, so a chunk boundary in the test is a
    /// chunk boundary the reader sees.
    ///
    /// - Parameters:
    ///   - chunks: The body in the order it arrives, one element per chunk.
    ///   - failure: The failure the body ends with, or `nil` for a body that ends cleanly.
    ///   - headers: The response header fields; none by default.
    ///   - status: The response status; `.ok` by default.
    public init(
      chunks: [Data],
      failure: TransportError? = nil,
      headers: HTTPFields = [:],
      status: HTTPResponse.Status = .ok
    ) {
      self.init(
        body: {
          // `AsyncThrowingStream` cannot carry a typed failure, so the seeded `TransportError`
          // travels as the base's untyped failure and `StreamedBody`'s default mapping hands it
          // back unchanged.
          StreamedBody(
            AsyncThrowingStream<Data, any Error> { continuation in
              for chunk in chunks { continuation.yield(chunk) }
              continuation.finish(throwing: failure)
            })
        },
        headers: headers,
        status: status)
    }
  }

  private typealias Handler = @Sendable (HTTPRequest) -> Result<Answer, TransportError>

  /// What one call resolved to under the lock. A handler is carried out of the critical section
  /// before it runs, because it is test-supplied code that may read the log or seed another answer.
  private enum Resolution {
    case answer(Result<Answer, TransportError>)
    case handler(Handler)
  }

  private struct State {
    var handlers: [String: Handler] = [:]
    var queue: [Result<Answer, TransportError>] = []
    var requests: [Call] = []
  }

  private let state: Mutex<State>

  /// Creates a transport whose queue holds `results` and then `answers`, to be returned in order.
  ///
  /// The two arguments seed one queue. Every outcome in `results` is wrapped in an ``Answer``
  /// delivering its response whole, and those come first, ahead of everything in `answers`, so a
  /// scenario written across both reads in the order the two arguments name.
  ///
  /// - Parameters:
  ///   - answers: The canned outcomes behind `results`, first to be returned first; empty by
  ///     default, for a transport driven by `results` or by handlers alone.
  ///   - results: The canned outcomes ahead of `answers`, each a ``/HTTPCore/Response`` delivered
  ///     whole, first to be returned first; empty by default.
  public init(
    answers: [Result<Answer, TransportError>] = [],
    results: [Result<Response, TransportError>] = []
  ) {
    state = Mutex(State(queue: results.map { $0.map { Answer($0) } } + answers))
  }

  /// The most recent call, or `nil` before any has been made.
  public var last: Call? {
    state.withLock { $0.requests.last }
  }

  /// Every call so far, in the order the transport received them.
  public var requests: [Call] {
    state.withLock { $0.requests }
  }

  /// Adds one answer to the back of the queue.
  ///
  /// A ``/HTTPCore/Response`` is queued by wrapping it in an ``Answer`` first, the way
  /// ``init(answers:results:)`` wraps every response in its `results`.
  ///
  /// ```swift
  /// transport.enqueue(.success(MockTransport.Answer(.ok(json: Fixtures.jsonObject(["id": "42"])))))
  /// ```
  ///
  /// - Parameter answer: The outcome to return once every answer already queued has been.
  public func enqueue(_ answer: Result<Answer, TransportError>) {
    state.withLock { $0.queue.append(answer) }
  }

  /// Returns the transport to its freshly constructed state: no queued answers, no handlers, no
  /// recorded calls.
  public func reset() {
    state.withLock { $0 = State() }
  }

  /// Registers the answer for every request that arrives at `path`, replacing any handler already
  /// registered for it.
  ///
  /// The key is the path without its query string, so a handler registered for `"/me"` answers a
  /// request for `"/me?x=1"` as well as one for `"/me"`, and a key that itself contains a `?`
  /// matches nothing. The handler receives the request as it arrived, whose `path` is the whole
  /// target, so a handler that varies its answer by query reads the query from there.
  ///
  /// The handler is synchronous and runs outside the transport's lock, so it may read ``requests``
  /// or seed further answers. It runs once per matching request, so one registration serves a burst
  /// of concurrent callers, and it answers a caller that streams and one that sends alike.
  ///
  /// ```swift
  /// let transport = MockTransport()
  /// transport.setHandler(forPath: "/me") { _ in
  ///   .success(MockTransport.Answer(.ok(json: Fixtures.jsonObject(["id": "42"]))))
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - path: The request path to match, without a query string.
  ///   - handler: The answer for a request at that path.
  public func setHandler(
    forPath path: String,
    handler: @escaping @Sendable (HTTPRequest) -> Result<Answer, TransportError>
  ) {
    state.withLock { $0.handlers[path] = handler }
  }

  /// Records the call, then answers it from the handler registered for its path, or from the queue.
  ///
  /// The body is handed over as the seeded ``Answer`` builds it, so a seeded failure reaches the
  /// caller through the sequence, after whatever chunks were seeded ahead of it, and nothing is
  /// wrapped a second time on the way out.
  ///
  /// This transport starts nothing of its own to fetch a body, so a caller that drops the sequence
  /// unread leaves nothing running behind it, and it suspends nowhere on the way to an answer, so
  /// resolving one checks no cancellation. Reading the body does: a ``/HTTPCore/StreamedBody``
  /// refuses a cancelled task, so a call read under cancellation fails with
  /// ``/HTTPCore/TransportError/cancelled``, which is where a live transport reports it too.
  ///
  /// ``/HTTPCore/Transport/send(_:body:options:)`` is the protocol's default over this method, so a
  /// buffered call arrives here too, takes the answer the queue or the handler gives it, and is
  /// recorded once.
  ///
  /// - Parameters:
  ///   - request: The request to record and answer.
  ///   - body: The body, recorded as given.
  ///   - options: The transport options, recorded as given.
  /// - Returns: The seeded response, whatever its status, with its body still to be read.
  /// - Throws: The seeded ``/HTTPCore/TransportError``, or one carrying
  ///   ``MockTransportFailure/noCannedResponse`` when nothing was seeded for this request.
  public func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> StreamedResponse
  {
    let resolution = state.withLock { state -> Resolution in
      state.requests.append(Call(body: body, options: options, request: request))
      if let path = request.path, let handler = state.handlers[Self.handlerKey(forPath: path)] {
        return .handler(handler)
      }
      guard !state.queue.isEmpty else {
        return .answer(
          .failure(.transport(kind: .other, underlying: MockTransportFailure.noCannedResponse)))
      }
      return .answer(state.queue.removeFirst())
    }

    let seeded: Answer
    switch resolution {
    case .answer(let result):
      seeded = try result.get()
    case .handler(let handler):
      seeded = try handler(request).get()
    }
    return StreamedResponse(
      body: seeded.makeBody(), headers: seeded.headers, status: seeded.status)
  }

  /// The handler table key a request matches: its path up to the first `?`.
  ///
  /// `HTTPRequest.path` is the `:path` pseudo-header, which carries the path and the query string
  /// together, so a request built from a path and query items arrives here as `"/me?x=1"`. Dropping
  /// the query from the key is what lets a handler registered for `"/me"` answer it.
  ///
  /// - Parameter path: The request's path, with or without a query string.
  /// - Returns: The path with any query string removed.
  private static func handlerKey(forPath path: String) -> String {
    guard let separator = path.firstIndex(of: "?") else { return path }
    return String(path[..<separator])
  }
}
