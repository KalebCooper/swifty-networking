// `AsyncHTTPClientTransport` exists only behind the `HTTPPortable` trait, so this suite compiles
// away without it.
#if HTTPPortable

import AsyncHTTPClient
import Foundation
import HTTPCore
import HTTPPortable
import HTTPTesting
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
import _NIOFileSystem

/// The body kinds a send attaches to the request.
enum BodyKind: Sendable {
  case bytes
  case file
  case none
}

/// Enough connections for twenty streams to be open at once: AsyncHTTPClient's default soft limit
/// per host is eight, and a stream past it would wait in the pool for one to end.
private let wideConfiguration = AsyncHTTPClient.HTTPClient.Configuration(
  connectionPool: .init(
    idleTimeout: .seconds(60), concurrentHTTP1ConnectionsPerHostSoftLimit: 32))

/// A `302` answer pointing at `/v1/end`, followed by the `200` that lives there.
private func redirectScript() -> [Answer] {
  [
    .response(
      chunks: [Data("moved".utf8)], headers: [("Location", "/v1/end")], status: 302),
    .response(chunks: [Data("arrived".utf8)], status: 200),
  ]
}

/// An error from a domain that has no mapping of its own.
private struct UnmappedError: Error {}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct AsyncHTTPClientTransportResponseTests {
  @Test("The status, header fields, and body reach the caller")
  func statusHeadersAndBodyReachTheCaller() async throws {
    let script = Script(answers: [
      .response(
        chunks: [Data("hello".utf8)], headers: [("Content-Type", "text/plain")], status: 200)
    ])
    try await withLoopback(script) { server, transport in
      let response = try await transport.send(
        target(of: server), body: .none, options: TransportOptions())

      #expect(response.status.code == 200)
      #expect(response.headers[.contentType] == "text/plain")
      #expect(text(response.body) == "hello")
      #expect(script.requests.count == 1)
    }
  }

  @Test(
    "Every status is returned rather than thrown",
    arguments: [200, 201, 204, 301, 400, 401, 404, 409, 429, 500, 503])
  func everyStatusIsReturnedRatherThanThrown(status: Int) async throws {
    let script = Script(answers: [.response(status: status)])
    try await withLoopback(script) { server, transport in
      let response = try await transport.send(
        target(of: server), body: .none, options: TransportOptions())

      #expect(response.status.code == status)
      #expect(script.requests.count == 1)
    }
  }

  @Test(
    "AsyncHTTPClientTransport returns a 3xx instead of following it",
    arguments: [BodyKind.none, .bytes, .file])
  func aRedirectIsReturnedNotFollowed(kind: BodyKind) async throws {
    let script = Script(answers: redirectScript())
    let body: TransportBody =
      switch kind {
      case .bytes: .bytes(Data("payload".utf8))
      case .file: .file(try temporaryFile(Data("payload".utf8)))
      case .none: .none
      }
    try await withLoopback(script) { server, transport in
      let response = try await transport.send(
        target(of: server, method: kind == .none ? .get : .post), body: body,
        options: TransportOptions())

      #expect(response.status.code == 302)
      #expect(response.headers[.location] == "/v1/end")
      #expect(text(response.body) == "moved")
      #expect(script.requests.count == 1)
    }
  }

  @Test("The request's header fields and body go out as given")
  func requestHeaderFieldsAndBodyGoOutAsGiven() async throws {
    let marker = try #require(HTTPField.Name("X-Request-Marker"))
    let script = Script(answers: [.response(status: 200)])
    var headerFields = HTTPFields()
    headerFields[.authorization] = "Bearer token"
    headerFields[marker] = "1"
    try await withLoopback(script) { server, transport in
      _ = try await transport.send(
        target(of: server, headerFields: headerFields, method: .post),
        body: .bytes(Data(#"{"id":1}"#.utf8)), options: TransportOptions())

      let call = try #require(script.last)
      #expect(call.method == "POST")
      #expect(call.uri == "/v1/things")
      #expect(call.header("Authorization") == "Bearer token")
      #expect(call.header("X-Request-Marker") == "1")
      #expect(text(call.body) == #"{"id":1}"#)
    }
  }

  @Test("A body-less request sends no body and announces no length")
  func aBodylessRequestSendsNoBody() async throws {
    let script = Script(answers: [.response(status: 200)])
    try await withLoopback(script) { server, transport in
      _ = try await transport.send(target(of: server), body: .none, options: TransportOptions())

      let call = try #require(script.last)
      #expect(call.body.isEmpty)
      #expect(call.header("Content-Length") == nil)
    }
  }

  @Test("A body goes out as given with its length announced")
  func aBodyGoesOutAsGivenWithItsLengthAnnounced() async throws {
    let payload = Data(#"{"id":1}"#.utf8)
    let script = Script(answers: [.response(status: 200)])
    try await withLoopback(script) { server, transport in
      _ = try await transport.send(
        target(of: server, method: .put), body: .bytes(payload), options: TransportOptions())

      let call = try #require(script.last)
      #expect(call.method == "PUT")
      #expect(call.body == payload)
      #expect(call.header("Content-Length") == "\(payload.count)")
    }
  }

  @Test("An empty body puts the same request on the wire as no body")
  func anEmptyBodyIsIndistinguishableFromNoBody() async throws {
    let script = Script(answers: [.response(status: 200), .response(status: 200)])
    try await withLoopback(script) { server, transport in
      _ = try await transport.send(
        target(of: server, method: .post), body: .bytes(Data()), options: TransportOptions())
      _ = try await transport.send(
        target(of: server, method: .post), body: .none, options: TransportOptions())

      let calls = script.requests
      #expect(calls.count == 2)
      #expect(calls.map(\.body) == [Data(), Data()])
      #expect(calls.map { $0.header("Content-Length") } == ["0", "0"])
    }
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct AsyncHTTPClientTransportFailureTests {
  @Test(
    "Each client error maps to its kind",
    arguments: [
      (HTTPClientError.emptyHost, TransportFailureKind.badURL),
      (HTTPClientError.emptyScheme, TransportFailureKind.badURL),
      (HTTPClientError.invalidURL, TransportFailureKind.badURL),
      (HTTPClientError.missingSocketPath, TransportFailureKind.badURL),
      (HTTPClientError.remoteConnectionClosed, TransportFailureKind.connectivity),
      (HTTPClientError.connectTimeout, TransportFailureKind.timedOut),
      (HTTPClientError.deadlineExceeded, TransportFailureKind.timedOut),
      (HTTPClientError.getConnectionFromPoolTimeout, TransportFailureKind.timedOut),
      (HTTPClientError.httpProxyHandshakeTimeout, TransportFailureKind.timedOut),
      (HTTPClientError.readTimeout, TransportFailureKind.timedOut),
      (HTTPClientError.socksHandshakeTimeout, TransportFailureKind.timedOut),
      (HTTPClientError.tlsHandshakeTimeout, TransportFailureKind.timedOut),
      (HTTPClientError.writeTimeout, TransportFailureKind.timedOut),
      (HTTPClientError.alreadyShutdown, TransportFailureKind.other),
      (HTTPClientError.unsupportedScheme("ftp"), TransportFailureKind.other),
    ])
  func eachClientErrorMapsToItsKind(error: HTTPClientError, expected: TransportFailureKind) throws {
    let mapped = AsyncHTTPClientTransport.failure(from: error)

    let (kind, underlying) = try #require(transportFailure(mapped))
    #expect(kind == expected)
    #expect(underlying as? HTTPClientError == error)
  }

  @Test(
    "A cancelled client error, a cancelled request stream, and a CancellationError are the cancellation case, not a kind"
  )
  func aCancelledErrorIsTheCancellationCase() {
    let fromClient = AsyncHTTPClientTransport.failure(from: HTTPClientError.cancelled)
    let fromStream = AsyncHTTPClientTransport.failure(from: HTTPClientError.requestStreamCancelled)
    let fromTask = AsyncHTTPClientTransport.failure(from: CancellationError())

    #expect(isCancelled(fromClient))
    #expect(fromClient.underlying == nil)
    #expect(isCancelled(fromStream))
    #expect(isCancelled(fromTask))
  }

  @Test(
    "Each channel error maps to its kind",
    arguments: [
      (ChannelError.alreadyClosed, TransportFailureKind.connectivity),
      (ChannelError.eof, TransportFailureKind.connectivity),
      (ChannelError.ioOnClosedChannel, TransportFailureKind.connectivity),
      (ChannelError.connectTimeout(.seconds(1)), TransportFailureKind.timedOut),
      (ChannelError.operationUnsupported, TransportFailureKind.other),
      (ChannelError.writeMessageTooLarge, TransportFailureKind.other),
    ])
  func eachChannelErrorMapsToItsKind(error: ChannelError, expected: TransportFailureKind) throws {
    let mapped = AsyncHTTPClientTransport.failure(from: error)

    let (kind, underlying) = try #require(transportFailure(mapped))
    #expect(kind == expected)
    #expect(underlying as? ChannelError == error)
  }

  @Test("A TransportError passes through the mapping unchanged")
  func aTransportErrorPassesThrough() throws {
    let mapped = AsyncHTTPClientTransport.failure(
      from: TransportError.transport(kind: .badURL, underlying: nil))

    let (kind, underlying) = try #require(transportFailure(mapped))
    #expect(kind == .badURL)
    #expect(underlying == nil)
  }

  @Test("An error from an unmapped domain is carried through as other")
  func anUnmappedErrorIsCarriedThroughAsOther() throws {
    let mapped = AsyncHTTPClientTransport.failure(from: UnmappedError())

    let (kind, underlying) = try #require(transportFailure(mapped))
    #expect(kind == .other)
    #expect(underlying is UnmappedError)
  }

  @Test("A refused connection is a connectivity failure carrying the connection error")
  func aRefusedConnectionIsAConnectivityFailure() async throws {
    // The server is stopped before the send, so the port it held refuses the connection.
    let server = try await LoopbackServer.start(Script())
    let request = target(of: server)
    try await server.stop()

    // The client retries a refused connection until its connect timeout, so the timeout is what
    // bounds this test, not the refusal; it is wide enough that the refusal lands first on a
    // loaded machine, where the timeout would read as a timeout instead.
    let configuration = AsyncHTTPClient.HTTPClient.Configuration(
      timeout: .init(connect: .milliseconds(250)))
    try await withTransport(configuration: configuration) { transport in
      let error = try #require(await failure(sending: request, through: transport))

      let (kind, underlying) = try #require(transportFailure(error))
      #expect(kind == .connectivity)
      #expect(underlying is IOError)
    }
  }

  @Test("A refused connection reached by host name is connectivity carrying the connection error")
  func aRefusedConnectionByHostNameIsAConnectivityFailure() async throws {
    // A host name goes through name resolution and a connection attempt per address, and the
    // failure of every attempt is reported as one `NIOConnectionError`; an address literal skips
    // both and reports the one attempt's `IOError`, which the test above sees.
    let server = try await LoopbackServer.start(Script())
    let port = try #require(server.authority.split(separator: ":").last)
    try await server.stop()
    let request = HTTPRequest(
      method: .get, scheme: "http", authority: "localhost:\(port)", path: "/v1/things")

    let configuration = AsyncHTTPClient.HTTPClient.Configuration(
      timeout: .init(connect: .milliseconds(250)))
    try await withTransport(configuration: configuration) { transport in
      let error = try #require(await failure(sending: request, through: transport))

      let (kind, underlying) = try #require(transportFailure(error))
      #expect(kind == .connectivity)
      #expect(underlying is NIOConnectionError)
    }
  }

  @Test("A caller cancelled before sending leaves with cancelled and sends nothing")
  func aCallerCancelledBeforeSendingLeavesWithCancelled() async throws {
    let script = Script(answers: [.response(status: 200)])
    try await withLoopback(script) { server, transport in
      // A task added to an already-cancelled group starts cancelled, which is deterministic where
      // racing a `cancel()` fired alongside it is not.
      let outcome = await withTaskGroup(of: TransportError?.self) { group in
        group.cancelAll()
        group.addTask { await failure(sending: target(of: server), through: transport) }
        return await group.next() ?? nil
      }

      let error = try #require(outcome)
      #expect(isCancelled(error))
      #expect(script.requests.isEmpty)
    }
  }

  @Test("Cancelling a buffered send parked on a server that never answers throws cancelled")
  func cancellingABufferedSendParkedOnTheServerThrowsCancelled() async throws {
    let script = Script(answers: [.hang])
    try await withLoopback(script) { server, transport in
      let call = Task { await failure(sending: target(of: server), through: transport) }
      await script.arrived.wait(forCount: 1)
      call.cancel()
      let error = try #require(await call.value)

      #expect(isCancelled(error))
    }
  }

  @Test("A request with no URL to send to is a bad URL and sends nothing")
  func aRequestWithNoURLToSendToIsABadURL() async throws {
    let script = Script()
    try await withLoopback(script) { _, transport in
      // No scheme and no authority, so no URL can be built from it and nothing is sent.
      let unsendable = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/v1/things")

      let error = try #require(await failure(sending: unsendable, through: transport))

      let (kind, underlying) = try #require(transportFailure(error))
      #expect(kind == .badURL)
      #expect(underlying == nil)
      #expect(script.requests.isEmpty)
    }
  }

  @Test("A request after shutdown fails as other carrying alreadyShutdown")
  func aRequestAfterShutdownFailsAsOther() async throws {
    let script = Script(answers: [.response(status: 200)])
    try await withServer(script) { server in
      let transport = AsyncHTTPClientTransport()
      try await transport.shutdown()

      let error = try #require(await failure(sending: target(of: server), through: transport))

      let (kind, underlying) = try #require(transportFailure(error))
      #expect(kind == .other)
      #expect(underlying as? HTTPClientError == .alreadyShutdown)
      #expect(script.requests.isEmpty)
    }
  }
}

/// The redirect refusal against a client that would follow, with a control leg proving it would.
@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct AsyncHTTPClientTransportRedirectTests {
  @Test("A client left to its own devices follows the redirect, so the refusals below do work")
  func aBareClientFollows() async throws {
    let script = Script(answers: redirectScript())
    try await withServer(script) { server in
      let (status, body) = try await withClient { client in
        let response = try await client.execute(
          HTTPClientRequest(url: "http://\(server.authority)/v1/things"), deadline: .distantFuture)
        return (response.status.code, try await response.body.collect(upTo: 1024))
      }

      #expect(status == 200)
      #expect(String(buffer: body) == "arrived")
      #expect(script.requests.map(\.uri) == ["/v1/things", "/v1/end"])
    }
  }

  @Test("send returns the 3xx a client would otherwise follow")
  func sendReturnsThe3xx() async throws {
    let script = Script(answers: redirectScript())
    try await withLoopback(script) { server, transport in
      let response = try await transport.send(
        target(of: server), body: .none, options: TransportOptions())

      #expect(response.status.code == 302)
      #expect(response.headers[.location] == "/v1/end")
      #expect(text(response.body) == "moved")
      #expect(script.requests.map(\.uri) == ["/v1/things"])
    }
  }

  @Test("stream returns the 3xx a client would otherwise follow")
  func streamReturnsThe3xx() async throws {
    let script = Script(answers: redirectScript())
    try await withLoopback(script) { server, transport in
      let response = try await transport.stream(
        target(of: server), body: .none, options: TransportOptions())

      #expect(response.status.code == 302)
      #expect(response.headers[.location] == "/v1/end")
      #expect(try await collect(response.body) == Array("moved".utf8))
      #expect(script.requests.map(\.uri) == ["/v1/things"])
    }
  }
}

/// What one path put on the wire, as the server recorded it, so two requests compare on what the
/// transport set.
private struct WireRequest: Equatable {
  let body: Data
  let headers: [String: String]
  let method: String
  let uri: String

  init(_ call: RecordedRequest) {
    body = call.body
    headers = Dictionary(
      call.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first }
    )
    method = call.method
    uri = call.uri
  }
}

/// Sends `body` through both paths on one transport and returns what each put on the wire.
private func bothPaths(
  _ body: TransportBody, headerFields: HTTPFields, method: HTTPRequest.Method
) async throws -> (sent: WireRequest, streamed: WireRequest) {
  let script = Script(answers: [.response(status: 200), .response(status: 200)])
  return try await withLoopback(script) { server, transport in
    let request = target(of: server, headerFields: headerFields, method: method)
    let options = TransportOptions(cachePolicy: .revalidate)

    _ = try await transport.send(request, body: body, options: options)
    let sent = try #require(script.last)
    let streamed = try await transport.stream(request, body: body, options: options)
    _ = try await collect(streamed.body)
    let streamedCall = try #require(script.last)
    return (WireRequest(sent), WireRequest(streamedCall))
  }
}

/// The body kinds and the options, as each reaches the request the client sends.
@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct AsyncHTTPClientTransportBoundaryTests {
  @Test("A file body is sent from the file with its size announced")
  func aFileBodyIsSentFromTheFile() async throws {
    let contents = Data("recording bytes".utf8)
    let file = try temporaryFile(contents)
    defer { try? FileManager.default.removeItem(at: file) }
    let script = Script(answers: [.response(status: 200)])
    try await withLoopback(script) { server, transport in
      _ = try await transport.send(
        target(of: server, method: .put), body: .file(file), options: TransportOptions())

      let call = try #require(script.last)
      #expect(call.body == contents)
      #expect(call.header("Content-Length") == "\(contents.count)")
    }
  }

  @Test("A streamed file body is sent from the file with its size announced")
  func aStreamedFileBodyIsSentFromTheFile() async throws {
    let contents = Data("recording bytes".utf8)
    let file = try temporaryFile(contents)
    defer { try? FileManager.default.removeItem(at: file) }
    let script = Script(answers: [.response(status: 200)])
    try await withLoopback(script) { server, transport in
      let response = try await transport.stream(
        target(of: server, method: .put), body: .file(file), options: TransportOptions())
      _ = try await collect(response.body)

      let call = try #require(script.last)
      #expect(call.body == contents)
      #expect(call.header("Content-Length") == "\(contents.count)")
    }
  }

  @Test("A file that cannot be opened is a bad URL carrying the file system's error, on both paths")
  func aMissingFileIsABadURL() async throws {
    let script = Script(answers: [.response(status: 200)])
    try await withLoopback(script) { server, transport in
      let request = target(of: server, method: .put)

      let sent = try #require(
        await failure(sending: request, body: .file(missingFile()), through: transport))
      let streamed = try #require(
        await streamFailure(sending: request, body: .file(missingFile()), through: transport))

      for error in [sent, streamed] {
        let (kind, underlying) = try #require(transportFailure(error))
        #expect(kind == .badURL)
        #expect(underlying is FileSystemError)
      }
      #expect(script.requests.isEmpty)
    }
  }

  @Test("A body URL that is not a file URL is a bad URL with nothing behind it")
  func aBodyURLThatIsNotAFileURLIsABadURL() async throws {
    let script = Script(answers: [.response(status: 200)])
    try await withLoopback(script) { server, transport in
      let error = try #require(
        await failure(
          sending: target(of: server, method: .put),
          body: .file(URL.fixture("https://example.com/upload.bin")), through: transport))

      let (kind, underlying) = try #require(transportFailure(error))
      #expect(kind == .badURL)
      #expect(underlying == nil)
      #expect(script.requests.isEmpty)
    }
  }

  @Test(
    "Every cache policy sends the request to the origin, because the client keeps no cache",
    arguments: [
      CachePolicy.cacheElseLoad, .cacheOnly, .ignoreCache, .revalidate, .standard,
    ])
  func everyCachePolicyReachesTheOrigin(policy: CachePolicy) async throws {
    let script = Script(answers: [.response(status: 200)])
    try await withLoopback(script) { server, transport in
      let response = try await transport.send(
        target(of: server), body: .none, options: TransportOptions(cachePolicy: policy))

      #expect(response.status.code == 200)
      #expect(script.requests.count == 1)
    }
  }

  // These three count the descriptors open on the file through `/proc/self/fd`, which Linux and
  // Android both provide and Darwin does not.
  #if os(Linux) || os(Android)
  @Test(
    "The file is closed once a buffered send returns, after a full upload and after a cancelled one"
  )
  func theFileIsClosedOnceABufferedSendReturns() async throws {
    // A file large enough that the upload is still in flight when the send is cancelled.
    let file = try temporaryFile(Data(count: 8 * 1024 * 1024))
    defer { try? FileManager.default.removeItem(at: file) }
    let script = Script(answers: [.response(status: 200), .hang])
    try await withLoopback(script) { server, transport in
      #expect(try openDescriptors(on: file) == 0)

      _ = try await transport.send(
        target(of: server, method: .put), body: .file(file), options: TransportOptions())
      #expect(try openDescriptors(on: file) == 0)

      let call = Task {
        await failure(
          sending: target(of: server, method: .put), body: .file(file), through: transport)
      }
      await script.arrived.wait(forCount: 2)
      call.cancel()
      let error = try #require(await call.value)
      #expect(isCancelled(error))
      #expect(try openDescriptors(on: file) == 0)
    }
  }

  @Test(
    "A server that answers before the upload is finished has the file closed after the client lets go, not under it"
  )
  func anEarlyAnswerClosesTheFileAfterTheClientLetsGo() async throws {
    // The origin answers at the head, long before an 8 MiB upload could finish; the client stops
    // sending at a `413` and the send returns it, with the file closed once the client is done.
    let file = try temporaryFile(Data(count: 8 * 1024 * 1024))
    defer { try? FileManager.default.removeItem(at: file) }
    let script = Script(answers: [.response(status: 413)])
    try await withLoopback(script) { server, transport in
      let response = try await transport.send(
        target(of: server, method: .put), body: .file(file), options: TransportOptions())

      #expect(response.status.code == 413)
      #expect(try openDescriptors(on: file) == 0)
    }
  }

  @Test(
    "A streamed file body holds the file open while it is being sent and closes it once the response is dropped"
  )
  func aStreamedFileBodyHoldsTheFileOpenWhileSending() async throws {
    let file = try temporaryFile(Data(count: 8 * 1024 * 1024))
    defer { try? FileManager.default.removeItem(at: file) }
    let script = Script(handler: { _ in .endless(chunk: Data(count: 64 * 1024)) })
    try await withLoopback(script) { server, transport in
      var response: StreamedResponse? = try await transport.stream(
        target(of: server, method: .put), body: .file(file), options: TransportOptions())
      #expect(response?.status.code == 200)
      await script.opened.wait(forCount: 1)
      #expect(try openDescriptors(on: file) == 1)

      response = nil
      await script.closed.wait(forCount: 1)

      // The close follows the connection closing by however long the cancelled task takes to
      // unwind; this yields to it rather than waiting on a clock.
      var open = try openDescriptors(on: file)
      for _ in 0..<1000 where open > 0 {
        await Task.yield()
        open = try openDescriptors(on: file)
      }
      #expect(open == 0)
    }
  }
  #endif

  @Test("send and stream present the same request for a bytes body")
  func sendAndStreamPresentTheSameRequestForABytesBody() async throws {
    let marker = try #require(HTTPField.Name("X-Request-Marker"))
    let payload = Data(#"{"id":1}"#.utf8)

    let (sent, streamed) = try await bothPaths(
      .bytes(payload), headerFields: [marker: "1"], method: .post)

    #expect(sent == streamed)
    #expect(sent.body == payload)
    #expect(sent.method == "POST")
    #expect(sent.uri == "/v1/things")
    #expect(sent.headers["x-request-marker"] == "1")
    #expect(sent.headers["content-length"] == "\(payload.count)")
  }

  @Test("send and stream present the same request for a file body")
  func sendAndStreamPresentTheSameRequestForAFileBody() async throws {
    let marker = try #require(HTTPField.Name("X-Request-Marker"))
    let contents = Data("recording bytes".utf8)
    let file = try temporaryFile(contents)
    defer { try? FileManager.default.removeItem(at: file) }

    let (sent, streamed) = try await bothPaths(
      .file(file), headerFields: [.contentType: "video/mp4", marker: "1"], method: .put)

    #expect(sent == streamed)
    #expect(sent.body == contents)
    #expect(sent.method == "PUT")
    #expect(sent.headers["content-length"] == "\(contents.count)")
    #expect(sent.headers["content-type"] == "video/mp4")
    #expect(sent.headers["x-request-marker"] == "1")
  }

  @Test("send and stream present the same request for no body")
  func sendAndStreamPresentTheSameRequestForNoBody() async throws {
    let marker = try #require(HTTPField.Name("X-Request-Marker"))

    let (sent, streamed) = try await bothPaths(.none, headerFields: [marker: "1"], method: .get)

    #expect(sent == streamed)
    #expect(sent.body.isEmpty)
    #expect(sent.method == "GET")
    #expect(sent.headers["x-request-marker"] == "1")
    #expect(sent.headers["content-length"] == nil)
  }
}

/// The streaming half of `AsyncHTTPClientTransport`, over the same loopback server the suites
/// above send through. Chunk boundaries and flow control are proven at the exchange, by hand, in
/// `StreamingExchangeTests`; here the body is asserted by its bytes.
@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct AsyncHTTPClientTransportStreamingTests {
  @Test("The status, header fields, and body reach the caller")
  func statusHeadersAndBodyReachTheCaller() async throws {
    let script = Script(answers: [
      .response(
        chunks: [Data("hello".utf8)], headers: [("Content-Type", "text/plain")], status: 200)
    ])
    try await withLoopback(script) { server, transport in
      let response = try await transport.stream(
        target(of: server), body: .none, options: TransportOptions())

      #expect(response.status.code == 200)
      #expect(response.headers[.contentType] == "text/plain")
      #expect(try await collect(response.body) == Array("hello".utf8))
      #expect(script.requests.count == 1)
    }
  }

  @Test("The bytes arrive in the order the origin sent them across every chunk it wrote")
  func theBytesArriveInTheOrderTheOriginSentThem() async throws {
    let sent = Array(UInt8(0)...UInt8(255))
    let script = Script(answers: [
      .response(chunks: (0..<4).map { Data(sent[($0 * 64)..<(($0 + 1) * 64)]) }, status: 200)
    ])
    try await withLoopback(script) { server, transport in
      let response = try await transport.stream(
        target(of: server), body: .none, options: TransportOptions())

      #expect(try await collect(response.body) == sent)
      #expect(script.requests.count == 1)
    }
  }

  @Test(
    "Every status is returned rather than thrown",
    arguments: [200, 201, 204, 301, 400, 401, 404, 409, 429, 500, 503])
  func everyStatusIsReturnedRatherThanThrown(status: Int) async throws {
    let script = Script(answers: [.response(status: status)])
    try await withLoopback(script) { server, transport in
      let response = try await transport.stream(
        target(of: server), body: .none, options: TransportOptions())

      #expect(response.status.code == status)
      #expect(try await collect(response.body) == [])
      #expect(script.requests.count == 1)
    }
  }

  @Test("The request's header fields and body go out as given")
  func requestHeaderFieldsAndBodyGoOutAsGiven() async throws {
    let marker = try #require(HTTPField.Name("X-Request-Marker"))
    let script = Script(answers: [.response(status: 200)])
    var headerFields = HTTPFields()
    headerFields[.authorization] = "Bearer token"
    headerFields[marker] = "1"
    try await withLoopback(script) { server, transport in
      let response = try await transport.stream(
        target(of: server, headerFields: headerFields, method: .post),
        body: .bytes(Data(#"{"id":1}"#.utf8)), options: TransportOptions())
      _ = try await collect(response.body)

      let call = try #require(script.last)
      #expect(call.method == "POST")
      #expect(call.header("Authorization") == "Bearer token")
      #expect(call.header("X-Request-Marker") == "1")
      #expect(text(call.body) == #"{"id":1}"#)
    }
  }

  @Test(
    "A body cut short by the origin reaches the reader as a connectivity failure after its bytes")
  func aBodyCutShortReachesTheReaderAsAConnectivityFailure() async throws {
    let script = Script(answers: [
      .response(chunks: [Data("partial".utf8)], closeAfterChunks: true, status: 200)
    ])
    try await withLoopback(script) { server, transport in
      let response = try await transport.stream(
        target(of: server), body: .none, options: TransportOptions())

      #expect(response.status.code == 200)
      let (received, failure) = await drain(response.body)
      #expect(
        received.reduce(into: [UInt8]()) { $0.append(contentsOf: $1) } == Array("partial".utf8))
      let error = try #require(failure)
      let (kind, underlying) = try #require(transportFailure(error))
      #expect(kind == .connectivity)
      guard case .invalidEOFState? = underlying as? HTTPParserError else {
        Issue.record(
          "expected the parser's end-of-input failure, got \(String(describing: underlying))")
        return
      }
    }
  }

  @Test("Cancelling the reader before the response arrives throws cancelled")
  func cancellingTheReaderBeforeTheResponseArrivesThrowsCancelled() async throws {
    let script = Script(answers: [.hang])
    try await withLoopback(script) { server, transport in
      let call = Task { await streamFailure(sending: target(of: server), through: transport) }
      await script.arrived.wait(forCount: 1)
      call.cancel()
      let error = try #require(await call.value)

      #expect(isCancelled(error))
    }
  }

  @Test("A caller cancelled before sending leaves with cancelled and sends nothing")
  func aCallerCancelledBeforeSendingLeavesWithCancelled() async throws {
    let script = Script(answers: [.response(chunks: [Data("hello".utf8)], status: 200)])
    try await withLoopback(script) { server, transport in
      let outcome = await withTaskGroup(of: TransportError?.self) { group in
        group.cancelAll()
        group.addTask {
          do throws(TransportError) {
            let response = try await transport.stream(
              target(of: server), body: .none, options: TransportOptions())
            _ = try await collect(response.body)
            return nil
          } catch {
            return error
          }
        }
        return await group.next() ?? nil
      }

      let error = try #require(outcome)
      #expect(isCancelled(error))
      #expect(script.requests.isEmpty)
    }
  }

  @Test("Twenty concurrent streams each receive their own bytes")
  func twentyConcurrentStreamsEachReceiveTheirOwnBytes() async throws {
    // Each request names its own body in its query, and the handler echoes it, so a body delivered
    // to the wrong reader reads as the wrong number.
    let script = Script { head in
      .response(
        chunks: [Data((head.uri.split(separator: "?").last.map(String.init) ?? "").utf8)],
        status: 200)
    }
    try await withLoopback(script, configuration: wideConfiguration) { server, transport in
      let received = await withTaskGroup(of: (Int, Result<String, TransportError>).self) { group in
        for number in 1...20 {
          group.addTask {
            do throws(TransportError) {
              let response = try await transport.stream(
                target(of: server, path: "/v1/things?n=\(number)"), body: .none,
                options: TransportOptions())
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
        let body = try #require(received[number])
        #expect(try body.get() == "n=\(number)")
      }
      #expect(script.requests.count == 20)
    }
  }

  @Test("Dropping twenty unread bodies cancels twenty requests and closes their connections")
  func droppingTwentyUnreadBodiesClosesTwentyConnections() async throws {
    let script = Script(handler: { _ in .endless(chunk: Data(count: 64 * 1024)) })
    try await withLoopback(script, configuration: wideConfiguration) { server, transport in
      var responses: [StreamedResponse]? = try await withThrowingTaskGroup(
        of: StreamedResponse.self
      ) {
        group in
        for _ in 1...20 {
          group.addTask {
            try await transport.stream(target(of: server), body: .none, options: TransportOptions())
          }
        }
        var responses: [StreamedResponse] = []
        for try await response in group {
          responses.append(response)
        }
        return responses
      }
      #expect(responses?.count == 20)
      await script.opened.wait(forCount: 20)

      // The only references to the twenty bodies go here, and with them every request still
      // fetching one.
      responses = nil
      await script.closed.wait(forCount: 20)

      #expect(script.requests.count == 20)
    }
  }

  @Test("Dropping the response while a file body is still being sent stops the send")
  func droppingTheResponseWhileAFileBodyIsStillBeingSentStopsTheSend() async throws {
    // A file large enough that the origin, which answers as soon as the head arrives, answers
    // long before the upload could finish.
    let file = try temporaryFile(Data(count: 8 * 1024 * 1024))
    defer { try? FileManager.default.removeItem(at: file) }
    let script = Script(handler: { _ in .endless(chunk: Data(count: 64 * 1024)) })
    try await withLoopback(script) { server, transport in
      var response: StreamedResponse? = try await transport.stream(
        target(of: server, method: .put), body: .file(file), options: TransportOptions())
      #expect(response?.status.code == 200)
      await script.opened.wait(forCount: 1)

      response = nil
      await script.closed.wait(forCount: 1)
    }
  }
}

/// The conversion of a client response's head, driven by hand for the one answer the network
/// never produces: a header field name this package cannot represent.
@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct AsyncHTTPClientTransportHeadTests {
  @Test("A header field name no HTTP field can carry fails the response naming the field")
  func anInvalidHeaderFieldNameFailsTheResponse() throws {
    let response = HTTPClientResponse(status: .ok, headers: ["Bad Name": "value"])

    let error: TransportError
    do throws(TransportError) {
      _ = try AsyncHTTPClientTransport.head(of: response)
      Issue.record("expected the head to fail")
      return
    } catch let caught {
      error = caught
    }
    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .other)
    let unreadable = try #require(underlying as? AsyncHTTPClientResponseFailure)
    guard case .invalidHeaderFieldName(let name) = unreadable else {
      Issue.record("expected an invalid header field name, got \(unreadable)")
      return
    }
    #expect(name == "Bad Name")
    #expect("\(unreadable)".contains("Bad Name"))
  }

  @Test("A status outside the range an HTTP response can carry fails the response naming it")
  func anUnrepresentableStatusFailsTheResponse() throws {
    // HTTP/1 parsing never delivers four digits, but an HTTP/2 `:status` is converted as any
    // integer, and building a status past 999 would trap.
    let response = HTTPClientResponse(status: .init(statusCode: 1234))

    let error: TransportError
    do throws(TransportError) {
      _ = try AsyncHTTPClientTransport.head(of: response)
      Issue.record("expected the head to fail")
      return
    } catch let caught {
      error = caught
    }
    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .other)
    let unreadable = try #require(underlying as? AsyncHTTPClientResponseFailure)
    guard case .unrepresentableStatus(let code) = unreadable else {
      Issue.record("expected an unrepresentable status, got \(unreadable)")
      return
    }
    #expect(code == 1234)
    #expect("\(unreadable)".contains("1234"))
  }

  @Test("The head carries the status, its reason phrase, and every header field")
  func theHeadCarriesTheStatusAndEveryField() throws {
    let response = HTTPClientResponse(
      status: .init(statusCode: 418, reasonPhrase: "I'm a teapot"),
      headers: ["Content-Type": "text/plain", "X-Request-Marker": "1"])

    let head = try AsyncHTTPClientTransport.head(of: response)

    #expect(head.status.code == 418)
    #expect(head.status.reasonPhrase == "I'm a teapot")
    #expect(head.headers[.contentType] == "text/plain")
    let marker = try #require(HTTPField.Name("X-Request-Marker"))
    #expect(head.headers[marker] == "1")
  }
}

#endif
