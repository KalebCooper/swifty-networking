// The transport and the SwiftNIO stack it sends through are fetched only when the `HTTPPortable`
// trait is enabled, so this target compiles to an empty module without it.
#if HTTPPortable

import AsyncHTTPClient
import HTTPCore
import HTTPTypes
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import Synchronization
import _NIOFileSystem

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A ``/HTTPCore/Transport`` that sends a request with AsyncHTTPClient, buffered or streamed.
///
/// This type is the binding between the package's transport contract and SwiftNIO's networking
/// stack, so `HTTPCore` sends on Linux and on Android. It converts the request, sends it, converts
/// the response, and maps a failure onto ``/HTTPCore/TransportError``. Retrying, credentials,
/// status interpretation, and decoding live in ``/HTTPCore/HTTPClient``, so the client
/// configuration is the only thing to configure here.
///
/// ```swift
/// import HTTPCore
/// import HTTPPortable
///
/// let transport = AsyncHTTPClientTransport()
/// let client = HTTPClient(
///   baseURL: URL(string: "https://api.example.com/v1")!,
///   transport: transport
/// )
///
/// let profile: Profile = try await client.execute(Request(path: "/me"))
///
/// try await transport.shutdown()
/// ```
///
/// ## Owning the Client
///
/// The transport builds the AsyncHTTPClient `HTTPClient` it sends through, and holds it for as long
/// as any copy of the transport lives; copies share one client and one connection pool. Redirects
/// are a setting on that client, not on a request, and the shared `HTTPClient.shared` follows them,
/// which is why the transport builds its own rather than taking one. The client is built with
/// redirects disallowed from the configuration you pass; every other setting in it, the connect and
/// read timeouts, the connection pool, TLS, HTTP/2, is honoured as given.
///
/// AsyncHTTPClient requires an explicit end of life: call ``shutdown()`` once, after the last
/// request, and await it. A transport released without one traps inside AsyncHTTPClient in a debug
/// build, which treats an un-shut-down client as a leak; in a release build the client leaks its
/// connections and event loops silently, which is the worse of the two. Build the transport where
/// the client is built, use it for the life of the client, and shut it down where the client is
/// dropped.
///
/// ## Honouring the Options
///
/// AsyncHTTPClient keeps no response cache, so ``/HTTPCore/TransportOptions/cachePolicy`` has no
/// effect here: every ``/HTTPCore/CachePolicy`` case, and `nil`, sends the request to the origin as
/// ``/HTTPCore/CachePolicy/standard`` would.
///
/// ## Sending a File
///
/// A ``/HTTPCore/TransportBody/file(_:)`` body is read from disk as it is sent on both paths, and
/// neither loads it whole. The file is read through SwiftNIO's file-system module, `NIOFileSystem`,
/// from the `_NIOFileSystem` product of swift-nio: it is opened once, its size is sent as the
/// request's `Content-Length`, and it is closed exactly once, when the exchange ends: on the
/// buffered path once the response has been read and on the streamed path once the body has ended
/// or been dropped, and in either case only after the client has stopped reading the file, so a
/// server that answers before the upload is finished does not have the file closed under the
/// read. A URL that is not a `file:` URL, or a file that cannot be opened or read, throws
/// ``/HTTPCore/TransportFailureKind/badURL``, carrying the file system's error when there is one.
///
/// ## Mapping a Failure
///
/// An `HTTPClientError` becomes a ``/HTTPCore/TransportError/transport(kind:underlying:)`` whose
/// kind is the class of failure a retry policy can act on, carrying the error itself, which
/// describes itself by its code alone and is safe to log:
///
/// | `HTTPClientError` | Kind |
/// | --- | --- |
/// | `emptyHost`, `emptyScheme`, `invalidURL`, `missingSocketPath` | ``/HTTPCore/TransportFailureKind/badURL`` |
/// | `remoteConnectionClosed` | ``/HTTPCore/TransportFailureKind/connectivity`` |
/// | `connectTimeout`, `deadlineExceeded`, `getConnectionFromPoolTimeout`, `httpProxyHandshakeTimeout`, `readTimeout`, `socksHandshakeTimeout`, `tlsHandshakeTimeout`, `writeTimeout` | ``/HTTPCore/TransportFailureKind/timedOut`` |
/// | Any other error, `unsupportedScheme` included | ``/HTTPCore/TransportFailureKind/other`` |
///
/// A `cancelled` error is ``/HTTPCore/TransportError/cancelled`` and not a kind at all, and so are
/// a `requestStreamCancelled`, which is a streamed request body cut off by its own cancellation,
/// and a `CancellationError`. The SwiftNIO errors that reach a request are placed too: an `IOError`
/// or a `NIOConnectionError`, which is how a refused or unreachable host is reported, a
/// `ChannelError` of `ioOnClosedChannel`, `alreadyClosed`, or `eof`, which is the connection going
/// away under the request, and `HTTPParserError.invalidEOFState`, which is the connection closing
/// part-way through a response, are ``/HTTPCore/TransportFailureKind/connectivity``; a
/// `ChannelError.connectTimeout` is ``/HTTPCore/TransportFailureKind/timedOut``; and a
/// `FileSystemError` from the body file is ``/HTTPCore/TransportFailureKind/badURL``. Any other
/// error is ``/HTTPCore/TransportFailureKind/other`` carrying itself.
///
/// A response whose header field names or status this package cannot represent is
/// ``/HTTPCore/TransportFailureKind/other`` carrying an ``AsyncHTTPClientResponseFailure`` that
/// names the field or the status.
///
/// ## Returning a Redirect
///
/// The client this transport builds is told not to follow a `3xx`, so one comes back as the
/// response it was, its `Location` field in place, and ``/HTTPCore/HTTPClient`` follows it or not
/// under its ``/HTTPCore/HTTPClient/redirectPolicy``.
public struct AsyncHTTPClientTransport: Transport {
  /// The client every request goes through, built with redirects disallowed.
  let client: AsyncHTTPClient.HTTPClient

  /// Creates a transport over a client built from the given configuration.
  ///
  /// The configuration's redirect setting is replaced with `disallow` before the client is built,
  /// so a `3xx` is always returned to ``/HTTPCore/HTTPClient``; everything else is taken as given.
  ///
  /// - Parameters:
  ///   - configuration: The AsyncHTTPClient configuration to build the client from; defaults to
  ///     AsyncHTTPClient's own defaults.
  ///   - eventLoopGroup: The event loops the client runs on; defaults to AsyncHTTPClient's shared
  ///     group.
  public init(
    configuration: AsyncHTTPClient.HTTPClient.Configuration = .init(),
    eventLoopGroup: any EventLoopGroup = AsyncHTTPClient.HTTPClient.defaultEventLoopGroup
  ) {
    var configuration = configuration
    configuration.redirectConfiguration = .disallow
    client = AsyncHTTPClient.HTTPClient(
      eventLoopGroup: eventLoopGroup, configuration: configuration)
  }

  /// Shuts down the client this transport sends through.
  ///
  /// Call this once, after the last request, and await it. Every copy of the transport shares the
  /// client, so shutting one down shuts them all down, and a request sent after it fails with
  /// ``/HTTPCore/TransportFailureKind/other`` carrying `HTTPClientError.alreadyShutdown`.
  ///
  /// - Throws: A ``/HTTPCore/TransportError`` when AsyncHTTPClient reports a shutdown failure,
  ///   mapped as any other failure is.
  public func shutdown() async throws(TransportError) {
    do {
      try await client.shutdown()
    } catch {
      throw Self.failure(from: error)
    }
  }

  /// Sends one request and returns the server's complete response.
  ///
  /// This overrides the protocol's default, which would drain ``stream(_:body:options:)``, with a
  /// direct read of the client's response body, so a buffered request runs no chunk buffer and no
  /// task of its own. The whole body is buffered before this returns, and the status is returned,
  /// not interpreted: a `404` comes back as a ``/HTTPCore/Response`` for the client to act on, and
  /// so does a `302`.
  ///
  /// A ``/HTTPCore/TransportBody/bytes(_:)`` body is sent as one buffer, a
  /// ``/HTTPCore/TransportBody/file(_:)`` body is streamed from the file with its size announced,
  /// and a body-less request sends none. The method is sent as given, so a `POST` with no body is
  /// sent as AsyncHTTPClient sends one, with a `Content-Length` of zero, and a body of zero bytes
  /// puts the same request on the wire.
  ///
  /// Cancelling the calling task cancels the request, which surfaces here as
  /// ``/HTTPCore/TransportError/cancelled``.
  ///
  /// ```swift
  /// let request = HTTPRequest(
  ///   method: .get, scheme: "https", authority: "api.example.com", path: "/health")
  /// let response = try await transport.send(request, body: .none, options: TransportOptions())
  /// print(response.status.code)
  /// ```
  ///
  /// - Parameters:
  ///   - request: The absolute request, with credentials and default header fields already applied.
  ///   - body: The body to send, or ``/HTTPCore/TransportBody/none`` for a body-less request.
  ///   - options: The settings this transport honours for the request; none apply here.
  /// - Returns: The response as received.
  /// - Throws: A ``/HTTPCore/TransportError`` when the request produced no response, or when its
  ///   body failed before it ended.
  public func send(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> Response
  {
    let clientRequest = try Self.clientRequest(for: request)
    // A caller cancelled before anything was sent is answered here, so no request goes on the wire.
    if Task.isCancelled {
      throw .cancelled
    }
    do {
      return try await Self.exchange(clientRequest, body: body, through: client) { response in
        let head = try Self.head(of: response)
        var collected = Data()
        for try await buffer in response.body {
          collected.append(Data(buffer: buffer))
        }
        return Response(body: collected, headers: head.headers, status: head.status)
      }
    } catch {
      throw Self.failure(from: error)
    }
  }

  /// Sends one request and returns the server's response with its body still arriving.
  ///
  /// The request is converted and a failure is mapped exactly as in ``send(_:body:options:)``.
  /// What differs is how the response is read: the exchange runs in a task of its own, which sends
  /// the request, settles the status and header fields, and then reads the client's body one
  /// buffer at a time into the returned sequence, each handed on exactly as the client delivered
  /// it. A chunk's boundary is where the client delivered one, and no chunk is split, joined, or
  /// held back.
  ///
  /// The status and header fields are settled before this returns, and the body follows a chunk at
  /// a time. The status is returned, not interpreted, so a `404` streams its error page like any
  /// other response and the client decides what that means.
  ///
  /// The body is buffered only as far as the reader is behind it. Chunks the reader has not taken
  /// yet are held up to 512 KiB, beyond which the exchange stops reading from the client, which
  /// stops reading from the connection; reading resumes once the reader has drained them to
  /// 128 KiB. A reader that keeps up never pauses the connection at all.
  ///
  /// Cancelling the calling task cancels the exchange, and so does releasing the returned
  /// ``/HTTPCore/StreamedResponse`` and every iterator over its body without reading it to the end:
  /// the request is cancelled, the connection is closed, and a file body still being sent stops
  /// and is closed with it. A client that throws on a non-2xx status, replays the request after a
  /// `401`, or reconnects a server-sent event stream leaves nothing fetching behind it. A caller
  /// already cancelled on entry sends nothing and throws ``/HTTPCore/TransportError/cancelled``; a
  /// cancellation that lands after the response has settled returns the `StreamedResponse`, whose
  /// body throws ``/HTTPCore/TransportError/cancelled`` on its first read.
  ///
  /// ```swift
  /// let request = HTTPRequest(
  ///   method: .get, scheme: "https", authority: "api.example.com", path: "/events")
  /// let response = try await transport.stream(request, body: .none, options: TransportOptions())
  /// for try await event in SSEDecoder(response.body) {
  ///   handle(event)
  /// }
  /// ```
  ///
  /// A failure that happens once the response is available reaches you through the body sequence
  /// as its ``/HTTPCore/TransportError`` failure, after every chunk delivered before it.
  /// ``/HTTPCore/HTTPClient`` reports it through ``/HTTPCore/TransportObserver/didFinishBody(_:)``
  /// once the body ends, from the consumer's own read.
  ///
  /// - Parameters:
  ///   - request: The absolute request, with credentials and default header fields already applied.
  ///   - body: The body to send, or ``/HTTPCore/TransportBody/none`` for a body-less request.
  ///   - options: The settings this transport honours for the request; none apply here.
  /// - Returns: The status and header fields as received, and the body as a sequence of chunks.
  /// - Throws: A ``/HTTPCore/TransportError`` when the request produced no response at all. A
  ///   failure after that surfaces from the returned sequence.
  public func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> StreamedResponse
  {
    let clientRequest = try Self.clientRequest(for: request)
    // A caller cancelled before anything was sent is answered here, so no request goes on the wire.
    if Task.isCancelled {
      throw .cancelled
    }

    let exchange = StreamingExchange()
    let client = client
    exchange.start {
      try await Self.exchange(clientRequest, body: body, through: client) { response in
        try await exchange.deliver(head: try Self.head(of: response), body: response.body)
      }
    } failure: { error in
      Self.failure(from: error)
    }

    // A caller cancelled while parked here cancels the exchange, and the cancellation comes back
    // through the exchange as its failure, so there is one path out either way. The handler
    // rethrows untyped, so the typed failure crosses it as a value.
    let answer: Result<StreamingExchange.Head, TransportError> = await withTaskCancellationHandler {
      do throws(TransportError) {
        return .success(try await exchange.response())
      } catch {
        return .failure(error)
      }
    } onCancel: {
      exchange.cancel()
    }
    let head = try answer.get()
    return StreamedResponse(body: exchange.makeBody(), headers: head.headers, status: head.status)
  }

  /// The AsyncHTTPClient request both paths send: the URL joined from the wire request's scheme,
  /// authority, and path, the method as given, and every header field as given.
  ///
  /// The conversion fails only for a request that names no URL a client could send: one with no
  /// scheme or no authority. A scheme the client does not speak is the client's to refuse.
  static func clientRequest(for request: HTTPRequest) throws(TransportError) -> HTTPClientRequest {
    guard let scheme = request.scheme, let authority = request.authority else {
      throw .transport(kind: .badURL, underlying: nil)
    }
    var clientRequest = HTTPClientRequest(url: "\(scheme)://\(authority)\(request.path ?? "")")
    clientRequest.method = HTTPMethod(rawValue: request.method.rawValue)
    for field in request.headerFields {
      clientRequest.headers.add(name: field.name.rawName, value: field.value)
    }
    return clientRequest
  }

  /// Runs one exchange: attaches the body, sends the request, and hands the response to `read`
  /// for as long as the body needs to be readable.
  ///
  /// This is the one place a file body is opened. The file is held open for the duration of
  /// `read`, so the buffered path closes it once the response body is collected and the streamed
  /// path once the body has ended or been dropped, and it is closed on every path out, including a
  /// cancellation. The client reads the file in a task of its own, which outlives `read` when the
  /// server answers before the upload is finished, so the scope waits for that task to let go of
  /// the file before closing it, unless the exchange is cancelled first. A body of bytes and no
  /// body take no such scope.
  private static func exchange<Value>(
    _ clientRequest: HTTPClientRequest, body: TransportBody,
    through client: AsyncHTTPClient.HTTPClient,
    _ read: @Sendable (HTTPClientResponse) async throws -> Value
  ) async throws -> Value {
    switch body {
    case .bytes(let data):
      var withBytes = clientRequest
      withBytes.body = .bytes(ByteBuffer(bytes: data))
      return try await read(try await client.execute(withBytes, deadline: .distantFuture))
    case .file(let url):
      guard url.isFileURL else {
        throw TransportError.transport(kind: .badURL, underlying: nil)
      }
      let path = FilePath(url.path(percentEncoded: false))
      return try await FileSystem.shared.withFileHandle(forReadingAt: path) { handle in
        let release = FileBody.Release()
        var withFile = clientRequest
        withFile.body = .stream(
          FileBody(chunks: handle.readChunks(), release: release),
          length: .known(try await handle.info().size))
        let outcome: Result<Value, any Error>
        do {
          outcome = .success(
            try await read(try await client.execute(withFile, deadline: .distantFuture)))
        } catch {
          outcome = .failure(error)
        }
        // A server that answered early leaves the client still holding the file's iterator until
        // its next write is refused; the handle closes after that, not under it.
        await release.wait()
        return try outcome.get()
      }
    case .none:
      return try await read(try await client.execute(clientRequest, deadline: .distantFuture))
    }
  }

  /// The status and header fields of a client response, in this package's types.
  ///
  /// Every field name and the status are validated on the way in, and one this package cannot
  /// represent fails the whole response rather than being dropped or trapping. The HTTP/1 parser
  /// never delivers a status past three digits, but an HTTP/2 `:status` is converted as any
  /// integer, so the range is checked here rather than assumed.
  package static func head(of response: HTTPClientResponse) throws(TransportError)
    -> StreamingExchange.Head
  {
    var headers = HTTPFields()
    for (name, value) in response.headers {
      guard let fieldName = HTTPField.Name(name) else {
        throw .transport(
          kind: .other,
          underlying: AsyncHTTPClientResponseFailure.invalidHeaderFieldName(name: name))
      }
      headers.append(HTTPField(name: fieldName, value: value))
    }
    let code = Int(response.status.code)
    guard (0...999).contains(code) else {
      throw .transport(
        kind: .other, underlying: AsyncHTTPClientResponseFailure.unrepresentableStatus(code: code))
    }
    let status = HTTPResponse.Status(code: code, reasonPhrase: response.status.reasonPhrase)
    return StreamingExchange.Head(headers: headers, status: status)
  }

  /// Maps an error the client reported onto the one error type the transport contract admits.
  ///
  /// The buffered and streaming calls share this mapping, and so does ``shutdown()``. A
  /// `TransportError` passes through unchanged, so a failure this transport raised itself inside a
  /// client call keeps its kind.
  package static func failure(from error: any Error) -> TransportError {
    if let error = error as? TransportError { return error }
    if error is CancellationError { return .cancelled }
    if let clientError = error as? HTTPClientError {
      // Cancellation is the caller's decision arriving as a client error, whether it cancelled the
      // request or the body it was streaming, and never a failure a retry policy should replay.
      guard clientError != .cancelled, clientError != .requestStreamCancelled else {
        return .cancelled
      }
      return .transport(kind: Self.kind(of: clientError), underlying: clientError)
    }
    if error is IOError || error is NIOConnectionError {
      return .transport(kind: .connectivity, underlying: error)
    }
    if let channelError = error as? ChannelError {
      // The connection going away under the request is connectivity; a channel that never
      // connected in time is a timeout; every other channel error says something about how the
      // channel was used, not about the network.
      switch channelError {
      case .alreadyClosed, .eof, .ioOnClosedChannel:
        return .transport(kind: .connectivity, underlying: error)
      case .connectTimeout:
        return .transport(kind: .timedOut, underlying: error)
      default:
        return .transport(kind: .other, underlying: error)
      }
    }
    // The parser reports the connection closing in the middle of a message; every other parse
    // failure is the origin's fault, not the network's.
    if case .invalidEOFState? = error as? HTTPParserError {
      return .transport(kind: .connectivity, underlying: error)
    }
    if error is FileSystemError {
      return .transport(kind: .badURL, underlying: error)
    }
    return .transport(kind: .other, underlying: error)
  }

  /// The class of failure an `HTTPClientError` belongs to.
  ///
  /// An error naming a distinction no policy acts on maps to `other`; the error itself stays
  /// readable as the wrapped error.
  static func kind(of error: HTTPClientError) -> TransportFailureKind {
    switch error {
    case .emptyHost, .emptyScheme, .invalidURL, .missingSocketPath:
      .badURL
    case .remoteConnectionClosed:
      .connectivity
    case .connectTimeout, .deadlineExceeded, .getConnectionFromPoolTimeout,
      .httpProxyHandshakeTimeout, .readTimeout, .socksHandshakeTimeout, .tlsHandshakeTimeout,
      .writeTimeout:
      .timedOut
    default:
      .other
    }
  }
}

/// A file's chunks as the client's request body, with the moment the client lets go of them
/// observable.
///
/// The client reads a streamed body in a task of its own. On a request the server answers early,
/// with a `413` before the upload has finished, that task outlives the response: the client pauses
/// the body when the head arrives, succeeds the request when the response ends, and ends the task
/// when its next write is refused. The scope that opened the file waits on ``Release`` for the
/// client's iterator to be released before closing the handle, so the last read completes against
/// an open file instead of a closed one.
private struct FileBody: AsyncSequence, Sendable {
  typealias Element = ByteBuffer
  typealias Failure = any Error

  /// The iterator the client reads through, holding the token whose release is the signal.
  struct AsyncIterator: AsyncIteratorProtocol {
    var chunks: FileChunks.AsyncIterator
    let token: Token

    mutating func next(isolation actor: isolated (any Actor)?) async throws(any Error)
      -> ByteBuffer?
    {
      try await chunks.next(isolation: actor)
    }
  }

  /// When the client has let go of the file: not before it took the iterator, and not until it
  /// dropped it.
  final class Release: Sendable {
    private struct State {
      var released = false
      var taken = false
      var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    /// Marks the iterator as taken, so ``wait()`` parks until it is released.
    func taken() {
      state.withLock { $0.taken = true }
    }

    /// Marks the iterator as released, waking a parked ``wait()``.
    func released() {
      let waiter = state.withLock { state in
        state.released = true
        return state.waiter.take()
      }
      waiter?.resume()
    }

    /// Returns once the client has released the iterator; at once when it never took one, and at
    /// once when the waiting task is cancelled, since a cancelled exchange closes the file under
    /// whatever is still reading it.
    func wait() async {
      await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let parked: Bool = state.withLock { state in
            guard state.taken, !state.released, !Task.isCancelled else { return false }
            state.waiter = continuation
            return true
          }
          if !parked {
            continuation.resume()
          }
        }
      } onCancel: {
        let waiter = state.withLock { $0.waiter.take() }
        waiter?.resume()
      }
    }
  }

  /// Held by the iterator alone, so its deinit is the client dropping the iterator.
  final class Token: Sendable {
    let release: Release

    init(release: Release) {
      self.release = release
    }

    deinit {
      release.released()
    }
  }

  let chunks: FileChunks
  let release: Release

  func makeAsyncIterator() -> AsyncIterator {
    release.taken()
    return AsyncIterator(chunks: chunks.makeAsyncIterator(), token: Token(release: release))
  }
}

#endif
