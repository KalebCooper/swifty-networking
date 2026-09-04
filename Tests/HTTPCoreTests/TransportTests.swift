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

/// A body delivering `chunks` in order, each as one element, then ending with `failure` or cleanly.
private func chunked(_ chunks: [Data], failure: TransportError? = nil) -> StreamedBody {
  // `AsyncThrowingStream` cannot carry a typed failure, so the `TransportError` travels as the
  // base's untyped failure and `StreamedBody`'s default mapping hands it back unchanged.
  StreamedBody(
    AsyncThrowingStream<Data, any Error> { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish(throwing: failure)
    })
}

/// Answers with a body naming the actor `stream(_:body:options:)` ran on.
private struct IsolationProbe: Transport {
  func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> StreamedResponse
  {
    // Bound to a typed local before the comparison: an assertions build of the compiler asserts on
    // `#isolation` compared in place.
    let isolation: (any Actor)? = #isolation
    let onMainActor = isolation === MainActor.shared
    return StreamedResponse(
      body: chunked([Data((onMainActor ? "main" : "none").utf8)]),
      headers: [:], status: .ok)
  }
}

/// Returns or throws the outcome it was seeded with.
private struct Canned: Transport {
  let outcome: Result<StreamedResponse, TransportError>

  func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> StreamedResponse
  {
    try outcome.get()
  }
}

/// The name `Echo` reflects each cache policy under: a table written down here, so a test states
/// the name it expects rather than deriving it from the case.
private func name(of policy: CachePolicy) -> String {
  switch policy {
  case .cacheElseLoad: "cache-else-load"
  case .cacheOnly: "cache-only"
  case .ignoreCache: "ignore-cache"
  case .revalidate: "revalidate"
  case .standard: "standard"
  }
}

/// Reflects the request, its bytes, and its cache policy back as a response.
private struct Echo: Transport {
  func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> StreamedResponse
  {
    let bytes: Data = if case .bytes(let data) = body { data } else { Data() }
    var headers: HTTPFields = [:]
    headers[.cacheControl] = options.cachePolicy.map(name(of:)) ?? "none"
    headers[.contentLength] = String(bytes.count)
    headers[.location] = request.url?.absoluteString ?? request.path ?? ""
    return StreamedResponse(body: chunked([bytes]), headers: headers, status: .ok)
  }
}

/// Streams through a `MockTransport` and leaves `send(_:body:options:)` to the protocol's default.
private struct Forwarding: Transport {
  let inner: MockTransport

  func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> StreamedResponse
  {
    try await inner.stream(request, body: body, options: options)
  }
}

/// A streamed `200` whose body is `chunks`, ending with `failure` when one is given.
private func answer(
  _ chunks: [String], failure: TransportError? = nil, headers: HTTPFields = [:]
) -> Result<StreamedResponse, TransportError> {
  .success(
    StreamedResponse(
      body: chunked(chunks.map { Data($0.utf8) }, failure: failure), headers: headers, status: .ok))
}

private let request = HTTPRequest(
  method: .get, scheme: "https", authority: "example.com", path: "/a")

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct TransportTests {
  @Test("A struct conformer compiles, is Sendable, and is callable from a nonisolated context")
  func callableFromNonisolatedContext() async throws {
    requireSendable(IsolationProbe.self)
    let response = try await IsolationProbe().send(
      request, body: .none, options: TransportOptions())
    #expect(response.status == .ok)
    #expect(String(decoding: response.body, as: UTF8.self) == "none")
  }

  @Test("A call from the main actor stays on the main actor: no hop out, no hop back")
  @MainActor
  func callableFromMainActor() async throws {
    let response = try await IsolationProbe().send(
      request, body: .none, options: TransportOptions())
    #expect(String(decoding: response.body, as: UTF8.self) == "main")
  }

  @Test("The request, body, and options arrive intact")
  func requestArrivesIntact() async throws {
    let body = Data("payload".utf8)
    let response = try await Echo().send(
      request, body: .bytes(body), options: TransportOptions(cachePolicy: .ignoreCache))
    #expect(response.body == body)
    #expect(response.headers[.cacheControl] == "ignore-cache")
    #expect(response.headers[.contentLength] == "7")
    #expect(response.headers[.location] == "https://example.com/a")
  }

  @Test("A non-success status is returned as a response, never thrown")
  func nonSuccessStatusIsAResponse() async throws {
    let transport = Canned(
      outcome: .success(StreamedResponse(body: chunked([]), headers: [:], status: .notFound)))
    let response = try await transport.send(request, body: .none, options: TransportOptions())
    #expect(response.status == .notFound)
  }

  @Test("A failure arrives as a typed TransportError, so the catch needs no cast")
  func failureIsTyped() async {
    let transport = Canned(outcome: .failure(.transport(kind: .timedOut, underlying: nil)))
    do {
      _ = try await transport.send(request, body: .none, options: TransportOptions())
      Issue.record("send should have thrown")
    } catch {
      let typed: TransportError = error
      #expect(typed.isTimeout)
    }
  }

  @Test("A conformer is usable both generically and through an existential")
  func usableGenericallyAndErased() async throws {
    func drive<T: Transport>(_ transport: T) async throws(TransportError) -> Response {
      try await transport.send(request, body: .none, options: TransportOptions())
    }
    let generic = try await drive(
      Canned(
        outcome: .success(StreamedResponse(body: chunked([]), headers: [:], status: .accepted))))
    #expect(generic.status == .accepted)

    let erased: any Transport = Canned(
      outcome: .success(StreamedResponse(body: chunked([]), headers: [:], status: .created)))
    let existential = try await erased.send(request, body: .none, options: TransportOptions())
    #expect(existential.status == .created)
  }

  @Test("The default send drains every chunk into the response body in order")
  func theDefaultSendDrainsEveryChunkInOrder() async throws {
    let transport = Canned(
      outcome: answer(["hel", "lo ", "world"], headers: [.contentType: "text/plain"]))

    let response = try await transport.send(request, body: .none, options: TransportOptions())

    #expect(String(decoding: response.body, as: UTF8.self) == "hello world")
    #expect(response.headers[.contentType] == "text/plain")
    #expect(response.status == .ok)
  }

  @Test("The default send maps a mid-body failure into the thrown error")
  func theDefaultSendMapsAMidBodyFailureIntoTheThrownError() async {
    let transport = Canned(
      outcome: answer(["half"], failure: .transport(kind: .connectivity, underlying: nil)))

    do {
      _ = try await transport.send(request, body: .none, options: TransportOptions())
      Issue.record("send should have thrown")
    } catch {
      guard case .transport(let kind, let underlying) = error else {
        Issue.record("expected a transport failure, got \(error)")
        return
      }
      #expect(kind == .connectivity)
      #expect(underlying == nil)
    }
  }

  @Test("A streamed request through the default drain records one call on the mock")
  func aStreamedRequestThroughTheDefaultDrainRecordsOneCallOnTheMock() async throws {
    let mock = MockTransport(answers: [
      .success(MockTransport.Answer(chunks: [Data("a".utf8), Data("b".utf8)]))
    ])
    let transport = Forwarding(inner: mock)

    let response = try await transport.send(request, body: .none, options: TransportOptions())

    #expect(String(decoding: response.body, as: UTF8.self) == "ab")
    #expect(mock.requests.count == 1)
    #expect(mock.last?.request.path == "/a")
  }
}
