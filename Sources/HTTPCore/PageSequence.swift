/// A sequence of decoded pages, each fetched after the one before it by a rule you supply.
///
/// ``HTTPClient/pages(_:as:next:)`` makes one, and ``HTTPClient/pages(_:as:decode:next:)`` makes one
/// with a decode closure you supply. Nothing is sent until the sequence is read. Each read
/// sends one request through ``client``, reads the successful response as a `Value` with
/// ``decode``, asks ``next`` where the following page lives, and then returns the page. When
/// ``next`` answers `nil`, the page just returned is the last one.
///
/// ```swift
/// let issues = client.pages(Request(path: "/repos/o/r/issues"), as: [Issue].self) { page, _ in
///   WebLink.links(in: page.headers)
///     .first { $0.relations.contains("next") }
///     .map { .link($0.target) }
/// }
///
/// for try await page in issues {
///   handle(page.value)
/// }
/// ```
///
/// ## Fetching a Page
///
/// Every page is its own logical request, so it passes through the whole pipeline: its own
/// correlation identifier, retries, deadline, redirects, credential rules, and observer events. A
/// request that sets the ``HTTPClient/correlationIDField`` itself keeps that value, so every page
/// fetched from it reuses the same identifier. A ``NextPage/request(_:)`` is resolved against
/// ``HTTPClient/baseURL`` like any request. A ``NextPage/link(_:)`` is resolved against the URL the
/// current page came from, after any redirect, and fetched with `GET`, no body, and the header fields
/// and options of the request that produced the current page, less `Content-Type` and
/// `Content-Length`. A reference that does not resolve to an absolute URL still lets the current
/// page return, and the next read throws ``TransportError/transport(kind:underlying:)`` with
/// ``TransportFailureKind/badURL``.
///
/// ## Decoding
///
/// ``decode`` reads each page's successful response as a `Value`. The JSON initializer below sets
/// it to decode JSON with ``HTTPClient/decoder``; a source whose pages are not JSON, or whose
/// `Value` is not `Decodable`, supplies its own:
///
/// ```swift
/// let manifests = client.pages(
///   Request(path: "/manifests"),
///   as: Manifest.self,
///   decode: { response in try ManifestCodec.decode(response.body) }
/// ) { page, request in
///   page.value.nextMarker.map { marker in
///     var next = request
///     next.query = [QueryItem(name: "marker", value: marker)]
///     return .request(next)
///   }
/// }
/// ```
///
/// ``decode`` runs once per page, inside the read that fetched it, over the whole response used for
/// that page: its ``Response/body``, ``Response/headers``, and ``Response/status``. A wrapper that
/// keeps the bytes alongside the decoded value returns them from inside the closure; the response is
/// not read a second time.
///
/// A page on another origin goes without `Authorization`, `Cookie`, `Proxy-Authorization`, and the
/// field ``HTTPClient/authentication``'s scheme writes into, whether you set the field yourself,
/// set it in ``HTTPClient/defaultHeaders``, or the client attached it. Every other header field
/// travels with every page as set.
///
/// ## Coalescing
///
/// The first request is sent with its ``RequestOptions/coalescingKey``. Every request after it is
/// sent with the key cleared, and the request handed to ``next`` has the key cleared already, the
/// first page's included. A key names one response, and two iterations sharing a key on later pages
/// would join each other's unrelated pages.
///
/// ## Ending
///
/// Any thrown error ends the sequence: the iterator is finished, and every later read returns `nil`.
/// There is no page limit; stop reading when you have enough. A ``NextPage/link(_:)`` that resolves
/// to the current page's URL fetches that page again. A consumer whose task is cancelled
/// sees ``TransportError/cancelled`` from its next read, and no page is fetched on a cancelled task.
public struct PageSequence<Value>: AsyncSequence, Sendable {
  /// One decoded page, with the header fields and status it arrived with.
  public typealias Element = DecodedResponse<Value>
  /// The only error a read can throw.
  public typealias Failure = TransportError

  /// The client every page is fetched through.
  public let client: HTTPClient

  /// How a page's successful response reads as a `Value`.
  ///
  /// It runs once per page, inside the read that fetched it, and receives the whole response: the
  /// body, header fields, and status the page arrived with. A non-success response never reaches it.
  /// A ``TransportError`` it throws ends the sequence as thrown; any other error ends it as
  /// ``TransportError/decode(underlying:)``.
  public let decode: @Sendable (Response) async throws -> Value

  /// Where the page after a given one lives, or `nil` when that page is the last.
  ///
  /// It receives the page just decoded and the request that produced it, with
  /// ``RequestOptions/coalescingKey`` cleared, so a following request is a copy with a field changed.
  /// After a page reached through ``NextPage/link(_:)``, that request keeps the path and query of the
  /// last request that was not a link, not the link's target.
  public let next: @Sendable (DecodedResponse<Value>, Request) -> NextPage?

  /// The request for the first page, relative to the client's base URL.
  public let request: Request

  /// Creates a sequence that fetches `request` through `client`, reads each page with `decode`, and
  /// then fetches each page `next` names.
  ///
  /// ```swift
  /// let manifests = PageSequence<Manifest>(
  ///   client: client,
  ///   decode: { response in try ManifestCodec.decode(response.body) },
  ///   next: { page, request in
  ///     page.value.nextMarker.map { marker in
  ///       var next = request
  ///       next.query = [QueryItem(name: "marker", value: marker)]
  ///       return .request(next)
  ///     }
  ///   },
  ///   request: Request(path: "/manifests")
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - client: The client every page is fetched through.
  ///   - decode: How a page's successful response reads as a `Value`.
  ///   - next: Where the page after a given one lives, or `nil` when that page is the last.
  ///   - request: The request for the first page.
  public init(
    client: HTTPClient,
    decode: @escaping @Sendable (Response) async throws -> Value,
    next: @escaping @Sendable (DecodedResponse<Value>, Request) -> NextPage?,
    request: Request
  ) {
    self.client = client
    self.decode = decode
    self.next = next
    self.request = request
  }

  /// An iterator that fetches the first page on its first read.
  public func makeAsyncIterator() -> Iterator {
    Iterator(self)
  }

  /// The iterator over a ``PageSequence``.
  ///
  /// It is not `Sendable`: it holds where the following page lives, which is in exclusive use by
  /// whichever task is reading it.
  public struct Iterator: AsyncIteratorProtocol {
    /// One decoded page.
    public typealias Element = DecodedResponse<Value>
    /// The only error `next()` can throw.
    public typealias Failure = TransportError

    /// The request the next read sends and where it goes, or `nil` once the sequence has ended.
    private var pending: (destination: HTTPClient.Destination, request: Request)?

    /// The sequence being iterated.
    private let sequence: PageSequence

    init(_ sequence: PageSequence) {
      self.sequence = sequence
      pending = (.base, sequence.request)
    }

    /// The next page.
    ///
    /// - Throws: ``TransportError/cancelled`` when the reading task is cancelled;
    ///   ``TransportError/decode(underlying:)`` when ``PageSequence/decode`` throws an error that is
    ///   not a ``TransportError``, and a ``TransportError`` it throws as it is;
    ///   ``TransportError/transport(kind:underlying:)`` with ``TransportFailureKind/badURL`` for a
    ///   link that does not resolve to an absolute URL; and whatever ``HTTPClient/execute(_:)->R``
    ///   throws for the page's request.
    public mutating func next(
      isolation actor: isolated (any Actor)? = #isolation
    ) async throws(TransportError) -> DecodedResponse<Value>? {
      // `perform` is `nonisolated(nonsending)`, so it already runs on `actor` and needs no hand-off.
      guard let (destination, request) = pending else { return nil }
      // Whatever happens below, this read is the last one unless it settles a following request.
      pending = nil
      guard !Task.isCancelled else { throw .cancelled }

      let page: DecodedResponse<Value>
      let url: String
      do throws(TransportError) {
        let delivery = try await sequence.client.perform(request, to: destination)
        let value = try await decoded(delivery.answer)
        page = DecodedResponse(
          headers: delivery.answer.headers, status: delivery.answer.status, value: value)
        url = delivery.url
      } catch {
        // Cancellation is read from the task and not from the failure, so a failure reported on a
        // cancelled task, whatever it says, reads as the cancellation it follows from.
        throw Task.isCancelled ? .cancelled : error
      }

      var produced = request
      produced.options.coalescingKey = nil
      pending = following(sequence.next(page, produced), after: produced, from: url)
      return page
    }

    /// The page's value, read by the sequence's decode closure.
    ///
    /// - Parameter response: The page's successful response.
    /// - Returns: The decoded value.
    /// - Throws: A ``TransportError`` the closure throws, unchanged; any other error as
    ///   ``TransportError/decode(underlying:)``.
    private func decoded(_ response: Response) async throws(TransportError) -> Value {
      do {
        return try await sequence.decode(response)
      } catch let error as TransportError {
        throw error
      } catch {
        throw .decode(underlying: error)
      }
    }

    /// The request that fetches what `nextPage` names and where it goes, or `nil` when it names
    /// nothing.
    ///
    /// A reference that does not resolve goes out as written, so the client throws
    /// ``TransportFailureKind/badURL`` for it before anything is sent.
    ///
    /// - Parameters:
    ///   - nextPage: Where the following page lives.
    ///   - request: The request that produced the current page, its coalescing key cleared.
    ///   - url: The absolute URL the current page came from, which a link resolves against.
    private func following(
      _ nextPage: NextPage?, after request: Request, from url: String
    ) -> (destination: HTTPClient.Destination, request: Request)? {
      switch nextPage {
      case nil:
        return nil
      case .link(let reference):
        // A `GET` with no body, so the fields that described the body go, as on a 303 redirect.
        var linked = request
        linked.body = .none
        linked.headers[.contentLength] = nil
        linked.headers[.contentType] = nil
        linked.method = .get
        // Resolution fails only against a URL with no scheme or authority, which a page's URL
        // always has.
        return (.absolute(URLReference.resolve(reference, against: url) ?? reference), linked)
      case .request(var derived):
        derived.options.coalescingKey = nil
        return (.base, derived)
      }
    }
  }
}

extension PageSequence where Value: Decodable & SendableMetatype {
  /// Creates a sequence that fetches `request` through `client`, decodes each page's body as JSON
  /// with ``HTTPClient/decoder``, and then fetches each page `next` names.
  ///
  /// Each page decodes as ``Response/decode(_:with:)`` decodes it: a body at or below 16 KiB where the
  /// reader runs, a larger one on the concurrent executor.
  ///
  /// ```swift
  /// let items = PageSequence<ItemPage>(client: client, next: { page, request in
  ///   page.value.nextCursor.map { cursor in
  ///     var next = request
  ///     next.query = [QueryItem(name: "cursor", value: cursor)]
  ///     return .request(next)
  ///   }
  /// }, request: Request(path: "/items"))
  /// ```
  ///
  /// - Parameters:
  ///   - client: The client every page is fetched through.
  ///   - next: Where the page after a given one lives, or `nil` when that page is the last.
  ///   - request: The request for the first page.
  public init(
    client: HTTPClient,
    next: @escaping @Sendable (DecodedResponse<Value>, Request) -> NextPage?,
    request: Request
  ) {
    self.init(
      client: client,
      decode: { response in try await response.decode(Value.self, with: client.decoder) },
      next: next,
      request: request
    )
  }
}
