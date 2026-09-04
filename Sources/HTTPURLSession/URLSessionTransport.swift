// `URLSession` and the loading system behind it exist only on Apple platforms, so this target
// compiles only where they do.
#if canImport(Darwin)

import Foundation
import HTTPCore
import HTTPTypes
import HTTPTypesFoundation

/// A ``/HTTPCore/Transport`` that sends a request with `URLSession`, buffered or streamed.
///
/// This type is the binding between the package's transport contract and Apple's networking stack.
/// It converts the request, sends it, converts the response, and maps a failure onto
/// ``/HTTPCore/TransportError``. Retrying, credentials, status interpretation, and decoding live in
/// ``/HTTPCore/HTTPClient``, so the session is the only thing to configure here.
///
/// ```swift
/// import HTTPCore
/// import HTTPURLSession
///
/// let client = HTTPClient(
///   baseURL: URL(string: "https://api.example.com/v1")!,
///   transport: URLSessionTransport()
/// )
/// ```
///
/// A transport is a `Sendable` value and holds no state of its own. Keep one alongside the client
/// or construct one at the call site; a `URLSession` is itself safe to share.
///
/// ## Choosing a Session
///
/// The default is `URLSession.shared`, which pools connections with everything else in the process
/// that uses it. Pass a session of your own where those defaults are wrong for the API, most often
/// to keep credentials out of shared cookie and cache storage:
///
/// ```swift
/// let configuration = URLSessionConfiguration.ephemeral
/// configuration.httpCookieStorage = nil
/// configuration.httpShouldSetCookies = false
/// configuration.timeoutIntervalForRequest = 30
/// configuration.urlCache = nil
///
/// let transport = URLSessionTransport(session: URLSession(configuration: configuration))
/// ```
///
/// The session configuration is where this transport's deadlines are set, through
/// `timeoutIntervalForRequest` and `timeoutIntervalForResource`, and where its cache lives, through
/// `urlCache` and `requestCachePolicy`.
///
/// ## Honouring the Options
///
/// A ``/HTTPCore/TransportOptions/cachePolicy`` is set on the `URLRequest` this transport sends, so
/// one request can skip the cache a session otherwise uses. `nil` leaves the session
/// configuration's `requestCachePolicy` in charge.
///
/// | ``/HTTPCore/CachePolicy`` | `URLRequest.CachePolicy` |
/// | --- | --- |
/// | ``/HTTPCore/CachePolicy/cacheElseLoad`` | `returnCacheDataElseLoad` |
/// | ``/HTTPCore/CachePolicy/cacheOnly`` | `returnCacheDataDontLoad` |
/// | ``/HTTPCore/CachePolicy/ignoreCache`` | `reloadIgnoringLocalCacheData` |
/// | ``/HTTPCore/CachePolicy/revalidate`` | `reloadRevalidatingCacheData` |
/// | ``/HTTPCore/CachePolicy/standard`` | `useProtocolCachePolicy` |
///
/// ## Sending a File
///
/// A ``/HTTPCore/TransportBody/file(_:)`` body is read from disk as it is sent on both paths, and
/// neither loads it whole. A file the transport cannot read fails differently on the two:
/// ``stream(_:body:options:)`` opens the file itself and throws
/// ``/HTTPCore/TransportFailureKind/badURL`` with no underlying error, while
/// ``send(_:body:options:)`` hands the URL to the session with no check of its own and throws
/// ``/HTTPCore/TransportFailureKind/other`` carrying whatever `URLError` the session reports.
///
/// ## Mapping a Failure
///
/// A `URLError` becomes a ``/HTTPCore/TransportError/transport(kind:underlying:)`` whose kind is
/// the class of failure a retry policy can act on, carrying a ``URLSessionTransportFailure`` that
/// holds the original error:
///
/// | `URLError.Code` | Kind |
/// | --- | --- |
/// | `badURL` | ``/HTTPCore/TransportFailureKind/badURL`` |
/// | `networkConnectionLost` | ``/HTTPCore/TransportFailureKind/connectivity`` |
/// | `notConnectedToInternet` | ``/HTTPCore/TransportFailureKind/connectivity`` |
/// | `timedOut` | ``/HTTPCore/TransportFailureKind/timedOut`` |
/// | `unsupportedURL` | ``/HTTPCore/TransportFailureKind/badURL`` |
/// | Any other code | ``/HTTPCore/TransportFailureKind/other`` |
///
/// A `cancelled` code is ``/HTTPCore/TransportError/cancelled`` and not a kind at all, and so is a
/// `CancellationError`. An error that is not a `URLError` is
/// ``/HTTPCore/TransportFailureKind/other`` carrying itself.
///
/// Two answers `URLSession` reports as successes carry no status to report: a response that is not
/// an `HTTPURLResponse`, and an `HTTPURLResponse` whose status falls outside the range HTTP
/// statuses represent. Both are ``/HTTPCore/TransportFailureKind/other`` carrying a
/// ``URLSessionResponseFailure`` that names what arrived.
///
/// ## Returning a Redirect
///
/// `URLSession` follows a `3xx` on its own, and this transport stops it: every task on both paths
/// carries a delegate that refuses the redirect, so the `3xx` comes back as the response it was,
/// its `Location` field in place, and ``/HTTPCore/HTTPClient`` follows it or not under its
/// ``/HTTPCore/HTTPClient/redirectPolicy``. The per-task delegate answers the redirect callback
/// first; everything else a session's own delegate handles, such as an authentication challenge or
/// task metrics, reaches it unchanged.
public struct URLSessionTransport: Transport {
  /// The session every request goes through.
  let session: URLSession

  /// Creates a transport that sends with the given session.
  ///
  /// - Parameter session: The session every request goes through; defaults to `URLSession.shared`.
  public init(session: URLSession = .shared) {
    self.session = session
  }

  /// Sends one request and returns the server's complete response.
  ///
  /// This overrides the protocol's default, which would drain ``stream(_:body:options:)``, with
  /// the session's own buffered calls, so a buffered request runs no chunk buffer and only the
  /// delegate that keeps the session from following a redirect. The whole body is buffered before
  /// this returns, and the status is returned, not interpreted: a `404` comes back as a
  /// ``/HTTPCore/Response`` for the client to act on, and so does a `302`.
  ///
  /// A ``/HTTPCore/TransportBody/bytes(_:)`` body goes out through `URLSession.upload(for:from:)`,
  /// a ``/HTTPCore/TransportBody/file(_:)`` body through `URLSession.upload(for:fromFile:)`, which
  /// reads the file as it sends and never loads it whole, and a body-less request through
  /// `URLSession.data(for:)`. Nothing else differs between the three: the method is sent as given,
  /// the length is reported the same way, the response is read the same way, and a failure is
  /// mapped by the same rule, a file the session cannot read included. A body of zero bytes is
  /// indistinguishable on the wire from no body at all.
  ///
  /// Cancelling the calling task cancels the underlying `URLSession` task, which surfaces here as
  /// ``/HTTPCore/TransportError/cancelled``.
  ///
  /// ```swift
  /// let request = HTTPRequest(
  ///   method: .get, scheme: "https", authority: "api.example.com", path: "/health")
  /// let response = try await URLSessionTransport().send(
  ///   request, body: .none, options: TransportOptions())
  /// print(response.status.code)
  /// ```
  ///
  /// - Parameters:
  ///   - request: The absolute request, with credentials and default header fields already applied.
  ///   - body: The body to send, or ``/HTTPCore/TransportBody/none`` for a body-less request.
  ///   - options: The settings this transport honours for the request.
  /// - Returns: The response as received.
  /// - Throws: A ``/HTTPCore/TransportError`` when the request produced no response.
  public func send(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> Response
  {
    let urlRequest = try Self.urlRequest(for: request, options: options)
    let delegate = RedirectRefusingDelegate()

    let data: Data
    let response: URLResponse
    do {
      switch body {
      case .bytes(let bytes):
        (data, response) = try await session.upload(
          for: urlRequest, from: bytes, delegate: delegate)
      case .file(let url):
        (data, response) = try await session.upload(
          for: urlRequest, fromFile: url, delegate: delegate)
      case .none:
        (data, response) = try await session.data(for: urlRequest, delegate: delegate)
      }
    } catch {
      throw Self.failure(from: error)
    }

    // URLSession reports both of the answers below as successes, so the error that says what
    // arrived instead is this transport's to supply.
    guard let httpURLResponse = response as? HTTPURLResponse else {
      throw .transport(
        kind: .other,
        underlying: URLSessionResponseFailure.notHTTP(
          responseType: String(describing: type(of: response)), url: response.url))
    }
    guard let httpResponse = httpURLResponse.httpResponse else {
      throw .transport(
        kind: .other,
        underlying: URLSessionResponseFailure.unrepresentableStatus(
          code: httpURLResponse.statusCode, url: httpURLResponse.url))
    }
    return Response(body: data, headers: httpResponse.headerFields, status: httpResponse.status)
  }

  /// Sends one request and returns the server's response with its body still arriving.
  ///
  /// The request is converted and a failure is mapped exactly as in ``send(_:body:options:)``.
  /// What differs is how the response is read: the request goes out as a `URLSessionDataTask` with
  /// a delegate of its own, and the body is the chunks that delegate receives, each handed on
  /// exactly as the loading system delivered it. A chunk's boundary is where the network delivered
  /// one, and no chunk is split, joined, or held back.
  ///
  /// The status and header fields are settled before this returns, and the body follows a chunk at
  /// a time. The status is returned, not interpreted, so a `404` streams its error page like any
  /// other response and the client decides what that means.
  ///
  /// A request that carries a body sends it on the same request the chunks come back on: a
  /// ``/HTTPCore/TransportBody/bytes(_:)`` body as the request's `httpBody`, and a
  /// ``/HTTPCore/TransportBody/file(_:)`` body as an `httpBodyStream` opened on the file, so the
  /// file is read as it is sent and never loaded whole. The file's size is set on the request as
  /// its `Content-Length`, as `upload(for:fromFile:)` sets it, and the method is sent as given, so
  /// a streamed `POST` presents the same request as a buffered one. When the loading system asks
  /// for the body again, the delegate opens a fresh stream on the same file. A file the stream
  /// cannot open, or whose size cannot be read, is a request the session could not send, and
  /// throws ``/HTTPCore/TransportFailureKind/badURL``.
  ///
  /// The body is buffered only as far as the reader is behind it. Chunks the reader has not taken
  /// yet are held up to 512 KiB, beyond which the task is suspended; it is resumed once the reader
  /// has drained them to 128 KiB. A reader that keeps up is never suspended at all.
  ///
  /// Cancelling the calling task cancels the underlying `URLSession` task, and so does discarding
  /// the returned body without reading it. A client that throws on a non-2xx status, or replays the
  /// request after a `401`, leaves nothing fetching behind it. A caller already cancelled on entry
  /// sends nothing and throws ``/HTTPCore/TransportError/cancelled``; a cancellation that lands
  /// after the response has settled returns the `StreamedResponse`, whose body throws
  /// ``/HTTPCore/TransportError/cancelled`` on its first read.
  ///
  /// ```swift
  /// let request = HTTPRequest(
  ///   method: .get, scheme: "https", authority: "api.example.com", path: "/events")
  /// let response = try await URLSessionTransport().stream(
  ///   request, body: .none, options: TransportOptions())
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
  ///   - options: The settings this transport honours for the request.
  /// - Returns: The status and header fields as received, and the body as a sequence of chunks.
  /// - Throws: A ``/HTTPCore/TransportError`` when the request produced no response at all. A
  ///   failure after that surfaces from the returned sequence.
  public func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> StreamedResponse
  {
    var urlRequest = try Self.urlRequest(for: request, options: options)
    switch body {
    case .bytes(let bytes):
      urlRequest.httpBody = bytes
    case .file(let url):
      // `InputStream(url:)` opens nothing for a URL that names no file it can read, and a body
      // that cannot be opened is a request the session could not send. The length goes on the
      // request because a body stream announces none: without it the session sends the file
      // chunked, which upload endpoints commonly reject, where the buffered path announces the
      // file's size.
      guard let fileStream = InputStream(url: url),
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
      else {
        throw .transport(kind: .badURL, underlying: nil)
      }
      urlRequest.httpBodyStream = fileStream
      urlRequest.setValue(String(size), forHTTPHeaderField: "Content-Length")
    case .none:
      break
    }
    // A caller cancelled before anything was sent is answered here, so no request goes on the wire.
    if Task.isCancelled {
      throw .cancelled
    }

    let task = session.dataTask(with: urlRequest)
    let bodyFile: URL? = if case .file(let url) = body { url } else { nil }
    let delegate = StreamingTaskDelegate(bodyFile: bodyFile, control: TaskControl(task: task))
    task.delegate = delegate
    task.resume()

    // A caller cancelled while parked here cancels the task, and the cancellation comes back
    // through the delegate as the task's completion, so there is one path out either way. The
    // handler rethrows untyped, so the typed failure crosses it as a value.
    let answer: Result<HTTPResponse, TransportError> = await withTaskCancellationHandler {
      do throws(TransportError) {
        return .success(try await delegate.response())
      } catch {
        return .failure(error)
      }
    } onCancel: {
      task.cancel()
    }
    let response = try answer.get()
    return StreamedResponse(
      body: delegate.makeBody(), headers: response.headerFields, status: response.status)
  }

  /// The `URLRequest` both paths send: the wire request converted, then the options applied.
  ///
  /// The conversion fails only for a request that names no URL a session could send.
  private static func urlRequest(for request: HTTPRequest, options: TransportOptions)
    throws(TransportError) -> URLRequest
  {
    guard var urlRequest = URLRequest(httpRequest: request) else {
      throw .transport(kind: .badURL, underlying: nil)
    }
    if let cachePolicy = options.cachePolicy {
      urlRequest.cachePolicy = Self.cachePolicy(for: cachePolicy)
    }
    return urlRequest
  }

  /// The `URLRequest` policy the transport-neutral hint names.
  private static func cachePolicy(for policy: CachePolicy) -> URLRequest.CachePolicy {
    switch policy {
    case .cacheElseLoad: .returnCacheDataElseLoad
    case .cacheOnly: .returnCacheDataDontLoad
    case .ignoreCache: .reloadIgnoringLocalCacheData
    case .revalidate: .reloadRevalidatingCacheData
    case .standard: .useProtocolCachePolicy
    }
  }

  /// Maps an error `URLSession` reported onto the one error type the transport contract admits.
  ///
  /// The buffered and streaming calls share this mapping.
  static func failure(from error: any Error) -> TransportError {
    if error is CancellationError { return .cancelled }
    guard let urlError = error as? URLError else {
      return .transport(kind: .other, underlying: error)
    }
    // Cancellation is the caller's decision arriving as a network error, and never a failure a
    // retry policy should replay.
    guard urlError.code != .cancelled else { return .cancelled }
    return .transport(
      kind: Self.kind(of: urlError.code), underlying: URLSessionTransportFailure(urlError))
  }

  /// The class of failure a `URLError` code belongs to.
  ///
  /// A code naming a distinction no policy acts on maps to `other`; the code itself stays readable
  /// on the wrapped `URLSessionTransportFailure`.
  static func kind(of code: URLError.Code) -> TransportFailureKind {
    switch code {
    case .badURL, .unsupportedURL: .badURL
    case .networkConnectionLost, .notConnectedToInternet: .connectivity
    case .timedOut: .timedOut
    default: .other
    }
  }
}

#endif
