// `Data`, `URL`, and the JSON coders are the only Foundation types this file needs. The iOS SDK
// ships no separate FoundationEssentials module, so full Foundation is imported where that is the
// only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTypes

/// A client that sends a relative ``Request`` through a ``Transport`` and returns what you asked
/// for.
///
/// Every policy a request passes through lives here: the base-URL join, default header fields, body
/// encoding, credentials, redirects, retries, coalescing, deadlines, status interpretation, and
/// decoding. A transport moves bytes and nothing more.
///
/// A client is a `Sendable` value. Construct one per API and pass copies around freely; the
/// collaborators it holds carry whatever state the configuration needs, and copies share them.
///
/// A client is one type, not a generic one. It holds its transport as `any Transport` and its
/// clock as `any Clock<Duration>`, so `HTTPClient` is spelled the same wherever it is stored or
/// injected, and a test swaps a mock transport underneath it without a type parameter appearing in the
/// code that uses it.
///
/// ```swift
/// import HTTPCore
/// import HTTPURLSession
///
/// struct Profile: Decodable {
///   let id: String
///   let name: String
/// }
///
/// let client = HTTPClient(
///   baseURL: URL(string: "https://api.example.com/v1")!,
///   transport: URLSessionTransport()
/// )
///
/// let profile: Profile = try await client.execute(Request(path: "/me"))
/// ```
///
/// Every initializer parameter but ``baseURL`` and ``transport`` has a default, and the defaults
/// are unopinionated: redirects followed, no retrying, no deadline, no credentials, no observer, a
/// `ContinuousClock`, a plain `JSONDecoder` and `JSONEncoder`.
///
/// ## Deriving a Client
///
/// A client is a value, so a variant of one is a copy with a property changed. Every public stored
/// property can be changed that way, ``transport`` included. A copy shares its original's
/// coalescer, and only assigning ``transport`` replaces it; assigning ``authentication`` leaves the
/// coalescer alone and changes the key a flight is filed under instead. See <doc:GettingStarted>.
///
/// ```swift
/// var beta = client
/// beta.baseURL = URL(string: "https://beta.example.com/v1")!
/// beta.defaultHeaders[.accept] = "application/json"
/// ```
///
/// ## Resolving a Request
///
/// ``baseURL`` is read as `scheme://authority[/path][?query]`, the request's ``Request/path`` is
/// appended to the base path, and the request's ``Request/query`` is percent-encoded after the
/// base's own query. ``defaultHeaders`` are applied first and each field name the request sets
/// replaces every default value of that name, while a `Content-Type` is derived from the body only
/// when neither of them set one. The join is the client's own, so it reads the same on every
/// platform. See <doc:GettingStarted>.
///
/// ```swift
/// // https://api.example.com/v1/people/7?fields=name
/// let request = Request(path: "/people/7", query: [QueryItem(name: "fields", value: "name")])
/// ```
///
/// ## Interpreting a Response
///
/// A status outside `2xx` is ``TransportError/httpStatus(body:code:headers:)`` on every entry
/// point, carrying the body and the header fields, so nothing is lost by throwing and a retry
/// predicate, a credential refresh, and an observer see the same failure whichever entry point you
/// called. The four run one pipeline and differ only in what they do with a successful body. See
/// <doc:ErrorModel>.
///
/// ```swift
/// let profile: Profile = try await client.execute(Request(path: "/me"))
/// let page: DecodedResponse<[Item]> = try await client.execute(Request(path: "/items"))
/// let report = try await client.execute(Request(path: "/report.csv")) as Response
/// try await client.executeExpectingNoContent(Request(method: .delete, path: "/session"))
/// ```
///
/// ## Streaming
///
/// ``stream(_:)`` returns a successful body as a ``StreamedBody`` while its chunks are still
/// arriving. Every transport streams, because ``Transport/stream(_:body:options:)`` is the
/// protocol's one requirement, and the client calls it directly.
/// ``events(_:maxLineLength:reconnectDelay:)`` reads a `text/event-stream` through it and
/// reconnects with `Last-Event-ID` when the stream ends. See <doc:Streaming>.
///
/// ```swift
/// let body = try await client.stream(Request(path: "/events"))
///
/// for try await event in SSEDecoder(body) {
///   handle(event)
/// }
/// ```
///
/// ## Isolation
///
/// Every entry point runs on the caller's actor until the transport truly suspends, and a decoded
/// value is returned as `sending`, so a `MainActor` caller decodes a non-`Sendable` model with no
/// hop and no conformance it did not want. To start a request synchronously up to that first
/// suspension, closing the window where a view's task is torn down before its request launches,
/// launch it with `Task.immediate`. See <doc:ConcurrencyPosture>.
///
/// ```swift
/// let inFlight = Task.immediate {
///   let profile: Profile = try await client.execute(Request(path: "/me"))
///   return profile
/// }
/// ```
///
/// ## Credentials
///
/// A request whose ``RequestOptions/requiresAuth`` is `true` is authenticated when an
/// ``authentication`` exists: the credential is read from ``Authentication/provider`` at send time
/// on every attempt, an expiring one is refreshed before the send, and a `401` earns one refresh
/// and one replay inside the same attempt. Without an ``authentication`` the request is sent as
/// written and a `401` is an ordinary status failure. See <doc:Authenticating>.
///
/// ```swift
/// var admin = client
/// admin.authentication = Authentication(provider: adminStore, refresher: adminRefresher)
/// ```
///
/// ## Redirects
///
/// A `3xx` response that names a `Location` is followed under ``redirectPolicy``, or under the
/// request's own ``RequestOptions/redirectPolicy`` when it sets one. A redirect the policy stops at
/// is returned as the response it was, so every entry point throws it as
/// ``TransportError/httpStatus(body:code:headers:)`` with the `Location` field in `headers`, and
/// ``RetryPolicy/retryable`` is offered it like any other status failure. See
/// <doc:RequestPolicies>.
///
/// ```swift
/// let download = Request(options: RequestOptions(redirectPolicy: .never), path: "/export")
/// ```
///
/// ## Retries
///
/// A request is attempted up to ``RetryPolicy/maxAttempts`` times, using the request's own
/// ``RequestOptions/retryPolicy`` when it sets one and the client's otherwise. After a failed
/// attempt with another behind it, ``RetryPolicy/retryable`` is offered a ``FailedAttempt``, and a
/// yes waits the server's `Retry-After` or the schedule's
/// ``BackoffSchedule/delay(forAttempt:)`` on the injected ``clock``, so a test advances the wait by
/// hand. See <doc:RequestPolicies>.
///
/// ```swift
/// let client = HTTPClient(
///   baseURL: URL(string: "https://api.example.com/v1")!,
///   retryPolicy: RetryPolicy(
///     backoff: BackoffSchedule(delays: [.milliseconds(100), .milliseconds(400)]),
///     maxAttempts: 3
///   ),
///   transport: URLSessionTransport()
/// )
/// ```
///
/// ## Deadlines
///
/// ``timeout`` bounds a whole logical request, every attempt and the waits between them included,
/// on the injected ``clock``; a request's own ``RequestOptions/timeout`` takes its place when set,
/// and `nil`, the default on both, means no deadline. Past it the request throws
/// ``TransportError/transport(kind:underlying:)`` with ``TransportFailureKind/timedOut``, whatever
/// the exchange was still doing is cancelled, and ``RetryPolicy/retryable`` is never asked. See
/// <doc:RequestPolicies>.
///
/// ```swift
/// let search = Request(options: RequestOptions(timeout: .seconds(5)), path: "/search")
/// ```
///
/// ## Coalescing
///
/// A request that sets ``RequestOptions/coalescingKey`` shares one exchange with every other
/// request in flight under the same key and the same credential, through this client or a copy of
/// it, and each caller interprets that one response for itself. A key of `nil`, the default, never
/// coalesces, and the client never derives one. See <doc:RequestPolicies>.
///
/// ```swift
/// let me = Request(options: RequestOptions(coalescingKey: "me"), path: "/me")
/// ```
///
/// ## Correlating and Reporting
///
/// Every logical request is stamped with a correlation identifier as it is resolved, so one
/// identifier covers every attempt, the `401` replay inside them, and a whole coalesced flight. It
/// comes from ``correlationIDGenerator``, unless ``correlationIDField`` names a field the defaults
/// or the request already set, in which case the value already there is adopted, and it reaches the
/// server only when ``correlationIDField`` is set. An ``observer``, when there is one, is told
/// about every send, a redirect hop and a `401` replay included; see ``TransportObserver`` for what
/// it receives and what it never does.
///
/// ```swift
/// let client = HTTPClient(
///   baseURL: URL(string: "https://api.example.com/v1")!,
///   observer: RequestLogger(),
///   transport: URLSessionTransport()
/// )
/// ```
public struct HTTPClient: Sendable {
  /// The credential source, and the rules around it, for a request whose
  /// ``RequestOptions/requiresAuth`` is `true`; `nil` sends every request anonymously.
  ///
  /// A copy of a client assigned another ``Authentication`` refreshes on that value's own gate and
  /// never joins an exchange sent under the original's credential; the coalescer is shared and the
  /// flight is keyed by the credential, so no other collaborator changes.
  public var authentication: Authentication?

  /// The base URL every request is resolved against, read as `scheme://authority[/path][?query]`.
  ///
  /// Assigning one parses it again, so a copy of a client can be pointed at another host.
  public var baseURL: URL {
    didSet { base = BaseURL(baseURL.absoluteString) }
  }

  /// The clock that times waits between attempts, and measures each send's duration for an
  /// observer. A test injects one it can advance by hand.
  public var clock: any Clock<Duration>

  /// The header field the correlation identifier is sent under; `nil`, the default, sends none.
  ///
  /// Setting it also makes the field an input: a request or a default header that already carries
  /// this name supplies the identifier instead of receiving one.
  public var correlationIDField: HTTPField.Name?

  /// Where a logical request's correlation identifier comes from, called once per request.
  public var correlationIDGenerator: @Sendable () -> String

  /// The decoder every typed `execute(_:)` call uses.
  ///
  /// A coder is a reference type and every copy of a client holds the same one, so a copy that
  /// needs different settings is given a fresh coder rather than configuring the one it inherited.
  public var decoder: JSONDecoder

  /// Header fields sent with every request, each replaceable per request by field name.
  public var defaultHeaders: HTTPFields

  /// The encoder every ``RequestBody/json(_:)`` body is produced with.
  ///
  /// A coder is a reference type and every copy of a client holds the same one, so a copy that
  /// needs different settings is given a fresh coder rather than configuring the one it inherited.
  public var encoder: JSONEncoder

  /// Where the client reports each send; `nil` reports nothing.
  public var observer: (any TransportObserver)?

  /// What the client does with a `3xx` that names a `Location`; ``RedirectPolicy/follow`` by
  /// default. A request's own ``RequestOptions/redirectPolicy`` takes precedence.
  public var redirectPolicy: RedirectPolicy

  /// Whether, how often, and after what wait a failed request is sent again. A request's own
  /// ``RequestOptions/retryPolicy`` takes precedence.
  public var retryPolicy: RetryPolicy

  /// How long a whole logical request may take on ``clock`` before it fails with
  /// ``TransportFailureKind/timedOut``; `nil`, the default, sets no deadline. A request's own
  /// ``RequestOptions/timeout`` takes precedence.
  ///
  /// The deadline covers every attempt and the waits between them, and it is the client's own,
  /// measured on ``clock``; a transport's per-connection deadline, such as a `URLSession`
  /// configuration's `timeoutIntervalForRequest`, is a separate and lower bound on each send. A
  /// deadline of zero or less has already passed, so the request fails at once.
  public var timeout: Duration?

  /// What moves the bytes.
  ///
  /// Every entry point sends through it, ``stream(_:)`` included. Assigning one points a copy of
  /// the client at another transport and gives the copy a coalescer of its own: a keyed request
  /// through the copy is never answered by an exchange the original sent through its transport,
  /// for the same reason a request under one credential never joins a flight sent under another.
  /// Copies taken after the assignment share the new coalescer.
  public var transport: any Transport {
    didSet { coalescer = RequestCoalescer() }
  }

  /// What one send attaches: the credential the provider held, and how it is written.
  ///
  /// The two travel together because the scheme belongs to the ``Authentication`` the token was
  /// read from, so a send renders from what it was handed rather than reading the client again.
  private struct Credential {
    /// How the token is written into the request's header fields.
    var scheme: Authentication.Scheme

    /// The credential as the provider holds it, with no scheme prefix.
    var token: String
  }

  /// What every event reported for one send carries, gathered in one place so the three report
  /// sites agree about the send they describe.
  private struct EventContext {
    /// The one-based ordinal of the attempt making the send.
    var attempt: Int

    /// Whether a credential went out on this send.
    var authAttached: Bool

    /// The identifier shared by every event about this logical request.
    var correlationID: String

    /// The method being sent.
    var method: HTTPRequest.Method

    /// The absolute target being sent to.
    var url: URL
  }

  /// A request the client has resolved: what goes on the wire, and what every event about it
  /// carries.
  ///
  /// Resolving happens once per logical request, so the correlation identifier is minted once and
  /// the target's `URL` is built once, however many attempts and replays follow.
  private struct Resolved {
    /// The body as the transport receives it, encoded where encoding was needed.
    var body: TransportBody

    /// The identifier every event about this request carries.
    var correlationID: String

    /// The settings the transport honours, projected from the request's options.
    var options: TransportOptions

    /// The absolute request as a transport receives it.
    var target: HTTPRequest

    /// The absolute target as the events that report it carry it.
    var url: URL

  }

  /// One request in a redirect chain: the first one as resolved, or the request a `Location` led
  /// to.
  ///
  /// The target carries no credential. The credential is applied when the hop is sent, because
  /// whether it goes out depends on where the hop is going.
  private struct Hop {
    /// The body this hop sends; ``TransportBody/none`` once a `301`, `302`, or `303` dropped it.
    var body: TransportBody

    /// Whether this hop's scheme, host, and port are the ones the request was resolved to.
    ///
    /// The first hop's are by definition, so its credential goes out whatever the origin looks
    /// like, and a later hop earns the credential only when this is `true`.
    var sameOrigin: Bool

    /// The request as the transport receives it, before any credential is applied.
    var target: HTTPRequest

    /// The absolute target as the events that report it carry it.
    var url: URL
  }

  /// The parsed base, split once so the join is a concatenation per request; `nil` when ``baseURL``
  /// could not be parsed, which every request then reports.
  private var base: BaseURL?

  /// The in-flight exchanges a keyed request through this client, or a copy of it, may join; a copy
  /// pointed at another transport takes a fresh one.
  private var coalescer = RequestCoalescer()

  /// How many bytes of a failed streamed response's body reach the failure thrown for it.
  ///
  /// 64 KiB holds an error envelope several times over and is far short of a body worth streaming,
  /// so the read ends promptly on a server that answers a failure with a payload.
  private static let errorBodyLimit = 64 * 1024

  /// How many redirects one send follows before the next `3xx` is returned as the response.
  ///
  /// Twenty is what the major browsers stop at, and a chain that long is a loop far more often
  /// than a route.
  private static let redirectLimit = 20

  /// Creates a client.
  ///
  /// ```swift
  /// let client = HTTPClient(
  ///   baseURL: URL(string: "https://api.example.com/v1")!,
  ///   transport: URLSessionTransport()
  /// )
  /// ```
  ///
  /// The transport and the clock lose their concrete types here: the client holds
  /// `any Transport` and `any Clock<Duration>`, so it is spelled `HTTPClient` wherever it is stored.
  ///
  /// - Parameters:
  ///   - authentication: The credential source and the rules around it; defaults to `nil`,
  ///     anonymous.
  ///   - baseURL: The base URL every request is resolved against.
  ///   - clock: The clock that times waits between attempts and measures each send; defaults to a
  ///     `ContinuousClock`.
  ///   - correlationIDField: The header field the correlation identifier is sent under; defaults to
  ///     `nil`, which sends none and leaves the identifier to the observer alone.
  ///   - correlationIDGenerator: Where each logical request's correlation identifier comes from;
  ///     defaults to a fresh UUID string.
  ///   - decoder: The decoder for typed responses; defaults to a plain `JSONDecoder()`.
  ///   - defaultHeaders: Header fields sent with every request; defaults to none.
  ///   - encoder: The encoder for JSON bodies; defaults to a plain `JSONEncoder()`.
  ///   - observer: The observer each send is reported to; defaults to `nil`, none.
  ///   - redirectPolicy: What the client does with a `3xx` that names a `Location`; defaults to
  ///     ``RedirectPolicy/follow``.
  ///   - retryPolicy: The client-wide retry policy; defaults to ``RetryPolicy/disabled``.
  ///   - timeout: The client-wide deadline for a whole request; defaults to `nil`, none.
  ///   - transport: What sends the resolved request, buffered or streamed.
  public init(
    authentication: Authentication? = nil,
    baseURL: URL,
    clock: any Clock<Duration> = ContinuousClock(),
    correlationIDField: HTTPField.Name? = nil,
    correlationIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
    decoder: JSONDecoder = JSONDecoder(),
    defaultHeaders: HTTPFields = [:],
    encoder: JSONEncoder = JSONEncoder(),
    observer: (any TransportObserver)? = nil,
    redirectPolicy: RedirectPolicy = .follow,
    retryPolicy: RetryPolicy = .disabled,
    timeout: Duration? = nil,
    transport: any Transport
  ) {
    self.authentication = authentication
    self.baseURL = baseURL
    self.clock = clock
    self.correlationIDField = correlationIDField
    self.correlationIDGenerator = correlationIDGenerator
    self.decoder = decoder
    self.defaultHeaders = defaultHeaders
    self.encoder = encoder
    self.observer = observer
    self.redirectPolicy = redirectPolicy
    self.retryPolicy = retryPolicy
    self.timeout = timeout
    self.transport = transport
    // Property observers do not run during initialization, so the base is parsed here as well as in
    // `baseURL`'s `didSet`.
    self.base = BaseURL(baseURL.absoluteString)
  }

  /// Sends the request and decodes its successful body as `R`.
  ///
  /// ```swift
  /// let profile: Profile = try await client.execute(Request(path: "/me"))
  /// ```
  ///
  /// The decoded value is returned as `sending`, so `R` need not be `Sendable` to cross into the
  /// caller's isolation. `R` must have a `Sendable` metatype, because the type itself is passed to
  /// the decoder and only a sendable metatype lets the result leave the decoder's region as
  /// `sending`. Every concrete type qualifies unless its `Decodable` conformance is isolated to a
  /// global actor.
  ///
  /// - Parameter request: The request, relative to ``baseURL``.
  /// - Returns: The decoded body.
  /// - Throws: ``TransportError/httpStatus(body:code:headers:)`` for a status outside `2xx`,
  ///   ``TransportError/decode(underlying:)`` when the body is not an `R`, and whatever the
  ///   transport or the body encoder threw.
  public func execute<R: Decodable & SendableMetatype>(_ request: Request)
    async throws(TransportError)
    -> sending R
  {
    let response = try await perform(request)
    return try await response.decode(with: decoder)
  }

  /// Sends the request and returns its successful response exactly as the transport delivered it.
  ///
  /// The body is not read. Use this entry point for bytes you decode yourself, or when you need
  /// only the status and header fields.
  ///
  /// ```swift
  /// let response: Response = try await client.execute(Request(path: "/report.csv"))
  /// ```
  ///
  /// - Parameter request: The request, relative to ``baseURL``.
  /// - Returns: The response, status and header fields and body untouched.
  /// - Throws: ``TransportError/httpStatus(body:code:headers:)`` for a status outside `2xx`, and
  ///   whatever the transport or the body encoder threw.
  public func execute(_ request: Request) async throws(TransportError) -> Response {
    try await perform(request)
  }

  /// Sends the request and decodes its successful body, keeping the header fields and status it
  /// arrived with.
  ///
  /// ```swift
  /// let page: DecodedResponse<[Item]> = try await client.execute(Request(path: "/items"))
  /// let etag = page.headers[.eTag]
  /// ```
  ///
  /// This is ``execute(_:)->R`` with the response's metadata kept: the same decode, through the
  /// same size rule, so a large body still parses off the caller's executor. Reach for it when a
  /// header field is part of the answer rather than a detail of delivering it. Which of the three
  /// `execute(_:)` overloads you get is decided by the type you annotate.
  ///
  /// The decoded value crosses back as `sending` inside the result, so `Value` need not be
  /// `Sendable`. `Value` must have a `Sendable` metatype, because the type itself is passed to the
  /// decoder and only a sendable metatype lets the result leave the decoder's region as `sending`.
  /// Every concrete type qualifies unless its `Decodable` conformance is isolated to a global
  /// actor.
  ///
  /// - Parameter request: The request, relative to ``baseURL``.
  /// - Returns: The decoded body, the response header fields, and the response status.
  /// - Throws: ``TransportError/httpStatus(body:code:headers:)`` for a status outside `2xx`,
  ///   ``TransportError/decode(underlying:)`` when the body is not a `Value`, and whatever the
  ///   transport or the body encoder threw.
  public func execute<Value: Decodable & SendableMetatype>(_ request: Request)
    async throws(TransportError)
    -> sending DecodedResponse<Value>
  {
    let response = try await perform(request)
    let value: Value = try await response.decode(with: decoder)
    return DecodedResponse(headers: response.headers, status: response.status, value: value)
  }

  /// Sends a request whose successful response carries nothing worth reading.
  ///
  /// Any `2xx` is accepted, `204` and an empty `200` alike, and a body the server sends anyway is
  /// discarded.
  ///
  /// ```swift
  /// try await client.executeExpectingNoContent(Request(method: .delete, path: "/session"))
  /// ```
  ///
  /// - Parameter request: The request, relative to ``baseURL``.
  /// - Throws: ``TransportError/httpStatus(body:code:headers:)`` for a status outside `2xx`, and
  ///   whatever the transport or the body encoder threw.
  public func executeExpectingNoContent(_ request: Request) async throws(TransportError) {
    _ = try await perform(request)
  }

  /// One logical request behind every entry point, bounded by its deadline when it has one.
  ///
  /// The exchange and the deadline race as two children of one group, so whichever finishes first
  /// decides and the other is cancelled. The deadline is the client's own, so it wraps the whole of
  /// `dispatch(_:)`: the retry loop sits inside the exchange child, which is what keeps a timeout
  /// from ever reaching ``RetryPolicy/retryable``, and a coalesced caller's deadline cancels that
  /// caller's wait alone, since the shared exchange runs in a task of its own. The children answer
  /// with a `Result` rather than throwing, because a group cannot carry a typed failure.
  private func perform(_ request: Request) async throws(TransportError) -> Response {
    guard let limit = request.options.timeout ?? timeout else { return try await dispatch(request) }

    let outcome = await withTaskGroup(
      of: Result<Response, TransportError>.self, returning: Result<Response, TransportError>.self
    ) { group in
      group.addTask {
        do throws(TransportError) {
          return .success(try await self.dispatch(request))
        } catch {
          return .failure(error)
        }
      }
      group.addTask {
        do throws(TransportError) {
          try await self.wait(limit)
          return .failure(.transport(kind: .timedOut, underlying: nil))
        } catch {
          // The exchange finished first, or the caller was cancelled: either way the deadline has
          // nothing to say, and a cancelled caller is answered `cancelled` by both children.
          return .failure(error)
        }
      }
      // A group answers `nil` only once it is empty, and both children are added above, so the first
      // answer is always there.
      guard let first = await group.next() else { return .failure(.cancelled) }
      group.cancelAll()
      return first
    }
    return try outcome.get()
  }

  /// One logical request run on its own, or shared with every request in flight under the same
  /// key.
  private func dispatch(_ request: Request) async throws(TransportError) -> Response {
    guard let key = request.options.coalescingKey else { return try await run(request) }
    // The flight is keyed by the credential the request goes out under as well as by the key, so a
    // response fetched under another token, or under none, is never handed to this caller.
    let identity = CoalescingIdentity(
      credential: request.options.requiresAuth ? authentication?.identity : nil, key: key)
    // A joiner never reaches the transport, so it reports nothing: the flight's own events are the
    // record of the one exchange, and a second set would count an attempt the server never saw.
    return try await coalescer.run(identity) { () async throws(TransportError) -> Response in
      try await self.run(request)
    }
  }

  /// The one pipeline behind every exchange: resolve once, then attempt until the policy stops.
  private func run(_ request: Request) async throws(TransportError) -> Response {
    let resolved = try resolve(request)
    let policy = request.options.retryPolicy ?? retryPolicy
    let redirects = request.options.redirectPolicy ?? redirectPolicy
    let requiresAuth = request.options.requiresAuth
    // A client always makes one attempt, so a policy asking for fewer asks for one.
    let attempts = max(policy.maxAttempts, 1)
    // Elapsed time is measured from here, inside the exchange, so it covers every send and every
    // wait between attempts and nothing of the deadline that races them from outside.
    let elapsed = clock.stopwatch()

    // Only an attempt with another behind it earns a retry decision. The last one's failure is the
    // caller's, so it is made past the loop and the policy is not asked about it.
    for number in 1..<attempts {
      do {
        return try await attempt(
          resolved, number: number, redirects: redirects, requiresAuth: requiresAuth)
      } catch {
        // A cancelled request is never sent again, whatever the predicate would answer.
        if case .cancelled = error { throw error }
        let failed = FailedAttempt(attempt: number, elapsed: elapsed(), failure: error)
        guard policy.retryable(failed) else { throw error }
        // A numeric `Retry-After` is the server's own answer to when, so it replaces the schedule's
        // delay outright, jitter included.
        try await wait(retryAfter(in: error) ?? policy.backoff.delay(forAttempt: number))
      }
    }
    return try await attempt(
      resolved, number: attempts, redirects: redirects, requiresAuth: requiresAuth)
  }

  /// Waits `delay` on the injected clock: the backoff between two attempts, or a request's deadline.
  ///
  /// Cancellation is checked here and not around a send, because a send the transport is already
  /// running cancels itself. Between attempts is the one place the client owns, and
  /// ``EventSource`` waits between connections through the same call.
  func wait(_ delay: Duration) async throws(TransportError) {
    do {
      try Task.checkCancellation()
      try await clock.sleep(for: delay, tolerance: .zero)
    } catch is CancellationError {
      throw .cancelled
    } catch {
      // Reachable only through a caller-supplied clock that fails a sleep for a reason of its own.
      throw .transport(kind: .other, underlying: error)
    }
  }

  /// The wait a status failure's `Retry-After` asks for, or `nil` for any other failure and for a
  /// field that names no number of seconds.
  private func retryAfter(in failure: TransportError) -> Duration? {
    guard case .httpStatus(body: _, code: _, headers: let headers) = failure else { return nil }
    return RetryAfter.delay(in: headers)
  }

  /// Turns the relative request into the absolute one a transport sends, with the header fields
  /// merged, the body encoded, and the correlation identifier settled.
  ///
  /// Encoding happens here, before anything is sent, so an encoding failure means nothing went on
  /// the wire. This runs once per logical request, so one identifier covers every attempt.
  private func resolve(_ request: Request) throws(TransportError) -> Resolved {
    guard let base else { throw .transport(kind: .badURL, underlying: nil) }

    let body: TransportBody
    let bodyContentType: String?
    // A multipart body's media type names a boundary the form minted, so it replaces a field the
    // request or the defaults carry instead of deferring to it. Every other body defers.
    var bodyContentTypeWins = false
    switch request.body {
    case .bytes(let data, let contentType):
      body = .bytes(data)
      bodyContentType = contentType
    case .file(let url, let contentType):
      body = .file(url)
      bodyContentType = contentType
    case .form(let items):
      body = .bytes(Data(items.formEncoded.utf8))
      bodyContentType = "application/x-www-form-urlencoded"
    case .json(let value):
      do {
        body = .bytes(try encoder.encode(value))
      } catch {
        throw .encode(underlying: error)
      }
      bodyContentType = "application/json"
    case .multipart(let form):
      body = .bytes(form.encoded)
      bodyContentType = form.contentType
      bodyContentTypeWins = true
    case .none:
      body = .none
      bodyContentType = nil
    }

    // Replacement is by field name, whole: a request that sets a name replaces every default value
    // of that name, and a request that sets a name twice keeps both of its values.
    var fields = defaultHeaders
    var replaced: Set<HTTPField.Name> = []
    for field in request.headers where replaced.insert(field.name).inserted {
      fields[fields: field.name] = request.headers[fields: field.name]
    }
    if let bodyContentType, bodyContentTypeWins || fields[.contentType] == nil {
      fields[.contentType] = bodyContentType
    }

    // The identifier is minted once for the whole request. A field already carrying this name is
    // adopted, not replaced: whoever set it upstream is already correlating on that value, and a
    // second identifier for the same request would break the trail in two.
    let correlationID: String
    if let correlationIDField, let assigned = fields[correlationIDField] {
      correlationID = assigned
    } else {
      correlationID = correlationIDGenerator()
      if let correlationIDField {
        fields[correlationIDField] = correlationID
      }
    }

    let target = HTTPRequest(
      method: request.method,
      scheme: base.scheme,
      authority: base.authority,
      path: base.target(path: request.path, query: request.query),
      headerFields: fields
    )
    // The events carry the URL the wire types synthesize from the pseudo-header fields, which is the
    // URL a `URLSession` transport sends to. A target the wire types cannot express as a URL would
    // fail there with the same kind, so it is refused here, before anything is sent.
    guard let url = target.url else { throw .transport(kind: .badURL, underlying: nil) }
    return Resolved(
      body: body,
      correlationID: correlationID,
      options: TransportOptions(cachePolicy: request.options.cachePolicy),
      target: target,
      url: url)
  }

  /// One attempt as the retry policy counts it: one exchange with the server, and the status of
  /// what came back interpreted.
  ///
  /// `number` is the one-based ordinal of this attempt, which is what the policy counts and what
  /// the events carry. The `401` replay inside one exchange does not advance it.
  ///
  /// The status is interpreted inside the attempt so that a status failure is offered to
  /// ``RetryPolicy/retryable`` alongside a transport one.
  private func attempt(
    _ resolved: Resolved, number: Int, redirects: RedirectPolicy, requiresAuth: Bool
  ) async throws(TransportError) -> Response {
    let response = try await exchange(
      resolved, number: number, redirects: redirects, requiresAuth: requiresAuth
    ) { (target, body, options) async throws(TransportError) in
      try await transport.send(target, body: body, options: options)
    }
    try checkStatus(response)
    return response
  }

  /// One exchange with the server: credential attached, sent, redirects followed, and, on a `401`
  /// the policy answers, refreshed once and sent once more.
  ///
  /// The whole `401` exchange lives inside a single attempt, so the retry loop sees one attempt
  /// whether or not a replay happened and "retry twice" composes with "replay once on `401`"
  /// without either counting the other. Every send here is reported under `number`, so a redirect
  /// hop or a replay is visible as another pair of events and not as an extra attempt.
  ///
  /// What the transport is asked for arrives as `call`, so a buffered response and a streamed one
  /// pass through one copy of the credential and redirect rules. Those rules read nothing but the
  /// status and the header fields, which both answers carry.
  private func exchange<Answer: ExchangeAnswer>(
    _ resolved: Resolved,
    number: Int,
    redirects: RedirectPolicy,
    requiresAuth: Bool,
    through call: (HTTPRequest, TransportBody, TransportOptions) async throws(TransportError)
      -> Answer
  ) async throws(TransportError) -> Answer {
    guard requiresAuth, let authentication else {
      return try await follow(
        resolved, credential: nil, number: number, redirects: redirects, through: call)
    }

    try await refreshIfExpiring(authentication)
    let sent = authentication.provider.currentToken()
    let response = try await follow(
      resolved, credential: credential(sent, under: authentication), number: number,
      redirects: redirects, through: call)
    guard response.status == .unauthorized, authentication.replayOn401,
      let refresher = authentication.refresher
    else { return response }

    // The refused answer is dropped unread. A streamed one cancels whatever was still fetching it,
    // which is what a streaming transport guarantees for a body nobody reads. The replay is the
    // request as written, sent with the new credential and followed again: a redirect is the
    // server's answer to that request, not a target the client may keep.
    try await authentication.gate.refresh(
      replacing: sent, of: authentication.provider, with: refresher)
    let replayed = authentication.provider.currentToken()
    return try await follow(
      resolved, credential: credential(replayed, under: authentication), number: number,
      redirects: redirects, through: call)
  }

  /// `token` paired with the scheme that renders it, or `nil` when the provider held none.
  ///
  /// The first send and the replay after a `401` pair them the same way, so which scheme renders a
  /// credential is decided in one place.
  private func credential(_ token: String?, under authentication: Authentication) -> Credential? {
    token.map { Credential(scheme: authentication.scheme, token: $0) }
  }

  /// One send, and every redirect hop `redirects` allows after it, until a response that is not a
  /// redirect the policy follows.
  ///
  /// The credential is applied at each send rather than carried on the target: the first send
  /// always gets it, and a hop only when it stays on the origin the request was resolved to, so
  /// the field the client attached never crosses to another host. A field the caller set is not
  /// the client's to remove and travels with every hop.
  ///
  /// A `3xx` answer that is followed is dropped unread, which on the streamed path cancels
  /// whatever was still fetching its body. The one returned, because the policy, the limit, or
  /// the `Location` stopped the chain, is the caller's to interpret.
  private func follow<Answer: ExchangeAnswer>(
    _ resolved: Resolved,
    credential: Credential?,
    number: Int,
    redirects: RedirectPolicy,
    through call: (HTTPRequest, TransportBody, TransportOptions) async throws(TransportError)
      -> Answer
  ) async throws(TransportError) -> Answer {
    // A base `BaseURL` accepted always names a scheme and an authority, but the authority may name
    // no host; then no hop can share the origin, and only the first send carries the credential.
    let origin = URLReference.Origin(
      authority: resolved.target.authority, scheme: resolved.target.scheme)
    var hop = Hop(body: resolved.body, sameOrigin: true, target: resolved.target, url: resolved.url)
    var followed = 0
    while true {
      let attached = hop.sameOrigin ? credential : nil
      let response = try await send(
        authorized(hop.target, with: attached),
        body: hop.body,
        context: EventContext(
          attempt: number,
          authAttached: attached != nil,
          correlationID: resolved.correlationID,
          method: hop.target.method,
          url: hop.url),
        options: resolved.options,
        through: call)
      guard followed < Self.redirectLimit,
        let next = nextHop(after: response, from: hop, origin: origin, redirects: redirects)
      else { return response }
      hop = next
      followed += 1
    }
  }

  /// The request a redirect leads to, or `nil` when `response` is not a redirect `redirects`
  /// follows from `hop`.
  ///
  /// Only a `301`, `302`, `303`, `307`, or `308` naming a `Location` is a redirect here. The
  /// `Location` is resolved against the hop's own URL and must name an authority; one that does
  /// not, or that the wire types cannot express as a URL, leaves the `3xx` as the response. The
  /// three older statuses turn the request into a `GET` with no body, a `HEAD` excepted, and
  /// drop the fields that described the body; the two newer keep everything.
  private func nextHop<Answer: ExchangeAnswer>(
    after response: Answer, from hop: Hop, origin: URLReference.Origin?, redirects: RedirectPolicy
  ) -> Hop? {
    guard redirects != .never, let location = response.headers[.location],
      let scheme = hop.target.scheme, let authority = hop.target.authority
    else { return nil }
    let keepsRequest: Bool
    switch response.status.code {
    case 301, 302, 303: keepsRequest = false
    case 307, 308: keepsRequest = true
    default: return nil
    }

    let current = "\(scheme)://\(authority)\(hop.target.path ?? "")"
    guard let resolved = URLReference.resolve(location, against: current) else { return nil }
    let parts = URLReference.parse(resolved)
    guard let nextScheme = parts.scheme, let nextAuthority = parts.authority else { return nil }
    let nextOrigin = URLReference.Origin(authority: nextAuthority, scheme: nextScheme)
    let sameOrigin = origin != nil && nextOrigin == origin
    guard redirects == .follow || sameOrigin else { return nil }

    // A request target is never empty, so a `Location` naming only an authority asks for its root,
    // as the base-URL join reads a base with no path.
    var path = parts.path.isEmpty ? "/" : parts.path
    if let query = parts.query {
      path.append("?")
      path.append(query)
    }
    var target = HTTPRequest(
      method: hop.target.method,
      scheme: nextScheme,
      authority: nextAuthority,
      path: path,
      headerFields: hop.target.headerFields)
    var body = hop.body
    if !keepsRequest {
      if target.method != .head { target.method = .get }
      body = .none
      target.headerFields[.contentLength] = nil
      target.headerFields[.contentType] = nil
    }
    guard let url = target.url else { return nil }
    return Hop(body: body, sameOrigin: sameOrigin, target: target, url: url)
  }

  /// Refreshes before sending when the rules have a threshold and the provider's remaining lifetime
  /// is at or below it. A provider that does not know its expiry, and a credential without a
  /// refresher, never refresh here.
  private func refreshIfExpiring(_ authentication: Authentication) async throws(TransportError) {
    guard let threshold = authentication.refreshThreshold, let refresher = authentication.refresher,
      let remaining = authentication.provider.timeUntilExpiry, remaining <= threshold
    else { return }
    try await authentication.gate.refresh(
      replacing: authentication.provider.currentToken(), of: authentication.provider,
      with: refresher)
  }

  /// The target with the credential rendered into the field its scheme names, or unchanged when
  /// there is none to render.
  private func authorized(_ target: HTTPRequest, with credential: Credential?) -> HTTPRequest {
    guard let credential else { return target }
    var authorized = target
    authorized.headerFields[credential.scheme.fieldName] = credential.scheme.value(
      for: credential.token)
    return authorized
  }

  /// One send through the transport, reported to the observer on its way out and on its way back.
  ///
  /// Every event the client emits is emitted here, so a send is reported once whether it is the
  /// first attempt, a retry, or the replay inside an attempt, and the `willSend`, `didReceive`,
  /// and `didFail` events for one send agree about what they describe. The duration is that send's
  /// own, measured across the transport call. A client without an observer reads no clock and
  /// builds no event.
  ///
  /// A streamed answer is reported here on the same terms. The send is the call that produced the
  /// status and the header fields, so `didReceive` reports a response that is available, not one
  /// that has finished arriving, and it carries no body preview because there are no bytes in hand.
  /// How the body ends is reported from the consumer's own read, through
  /// ``TransportObserver/didFinishBody(_:)``, and is past every event reported here.
  private func send<Answer: ExchangeAnswer>(
    _ target: HTTPRequest,
    body: TransportBody,
    context: EventContext,
    options: TransportOptions,
    through call: (HTTPRequest, TransportBody, TransportOptions) async throws(TransportError)
      -> Answer
  ) async throws(TransportError) -> Answer {
    guard let observer else { return try await call(target, body, options) }

    observer.willSend(
      RequestEvent(
        attempt: context.attempt,
        authAttached: context.authAttached,
        correlationID: context.correlationID,
        method: context.method,
        url: context.url))
    let (duration, outcome) = await clock.timed { () async throws(TransportError) in
      try await call(target, body, options)
    }
    switch outcome {
    case .success(let response):
      observer.didReceive(
        ResponseEvent(
          attempt: context.attempt,
          authAttached: context.authAttached,
          bodyPreview: response.previewableBody.flatMap { observer.bodyPreview(of: $0) },
          correlationID: context.correlationID,
          duration: duration,
          method: context.method,
          status: response.status,
          url: context.url))
      return response
    case .failure(let error):
      // A failure that never produced a response has no body to preview.
      observer.didFail(
        FailureEvent(
          attempt: context.attempt,
          authAttached: context.authAttached,
          correlationID: context.correlationID,
          duration: duration,
          failure: error,
          method: context.method,
          url: context.url))
      throw error
    }
  }

  /// Turns a status outside `2xx` into the failure every entry point throws for it.
  private func checkStatus(_ response: Response) throws(TransportError) {
    guard response.status.kind == .successful else {
      throw .httpStatus(body: response.body, code: response.status.code, headers: response.headers)
    }
  }

  /// Reads a failed streamed response's body as far as ``errorBodyLimit`` and no further.
  ///
  /// The bytes are truncated exactly at the limit, and releasing the body afterwards is what tells
  /// whatever was fetching it to stop. A failure part-way through the read ends it as well and
  /// whatever arrived stands, because the status is the failure the caller is being told about and
  /// a second one reported in its place would lose it.
  ///
  /// - Parameter body: The failed response's body.
  /// - Returns: The bytes read, at most ``errorBodyLimit`` of them.
  private func errorBody(_ body: StreamedBody) async -> Data {
    var collected = Data()
    do throws(TransportError) {
      for try await chunk in body {
        collected.append(chunk.prefix(Self.errorBodyLimit - collected.count))
        if collected.count >= Self.errorBodyLimit { break }
      }
    } catch {
      // What arrived before the failure is what the failure carries.
    }
    return collected
  }

  /// Sends the request and returns its successful response body as the chunks arrive.
  ///
  /// The status and the header fields are settled before this method returns, so receiving a
  /// sequence means the server accepted the request. Everything after that is the body, a chunk at
  /// a time, as a ``StreamedBody`` you can store or hand on without naming the transport's own
  /// sequence. Read it once, from one task: an `AsyncSequence` iterator is in exclusive use by
  /// whoever is reading it.
  ///
  /// Every transport streams: ``Transport/stream(_:body:options:)`` is the protocol's one
  /// requirement, and this method calls it directly on ``transport``.
  ///
  /// ```swift
  /// let body = try await client.stream(Request(path: "/events"))
  ///
  /// for try await event in SSEDecoder(body) {
  ///   handle(event)
  /// }
  /// ```
  ///
  /// ## What Streaming Shares with execute(_:)
  ///
  /// The resolution, the credential rules, and the redirect rules are the same code, and all are
  /// safe here because the status is settled before any chunk is delivered. Three policies do not
  /// apply: no retry, since a second attempt cannot replay chunks a consumer has already read; no
  /// coalescing, since one sequence cannot be read by several callers; and no deadline, since a
  /// body that keeps arriving is the point of streaming. A status outside `2xx` throws
  /// ``TransportError/httpStatus(body:code:headers:)`` carrying the first 64 KiB of the body,
  /// truncated exactly there when the server sent more, and the read is dropped at that point so
  /// the transport stops fetching. A failure while those bytes are being read ends the read too,
  /// and whatever arrived stands. Cancellation is not one of those failures: a caller cancelled
  /// during the read leaves with ``TransportError/cancelled`` as it does from any other point in
  /// the call, and the bytes that had arrived go with the read. No deadline covers the read, since
  /// none covers a stream, so an error body that neither ends nor fills the limit parks the caller
  /// until the transport's own deadline. See <doc:Streaming>.
  ///
  /// ```swift
  /// do {
  ///   let body = try await client.stream(Request(path: "/events"))
  ///   for try await chunk in body { handle(chunk) }
  /// } catch .httpStatus(let body, let code, _) {
  ///   report(message(in: body) ?? "HTTP \(code)")
  /// } catch {
  ///   report(error.description)
  /// }
  /// ```
  ///
  /// ## What an Observer Sees
  ///
  /// ``TransportObserver/willSend(_:)`` and ``TransportObserver/didReceive(_:)`` are reported as
  /// usual, the latter when the response becomes available, carrying the real status and a `nil`
  /// body preview, and ``TransportObserver/didFail(_:)`` is reported for a failure that happens
  /// before the sequence is returned. Once the sequence is yours, the one event left is
  /// ``TransportObserver/didFinishBody(_:)``, reported inline in the read that reached the end of
  /// the body or its failure, with the bytes your reads returned and the failure if there was one.
  /// A body dropped before it ended reports nothing. See <doc:Streaming>.
  ///
  /// ```swift
  /// let body = try await client.stream(Request(path: "/events"))
  ///
  /// for try await chunk in body {
  ///   handle(chunk)
  /// }
  /// // The read that ended the loop reported didFinishBody before returning.
  /// ```
  ///
  /// - Parameter request: The request, relative to ``baseURL``.
  /// - Returns: The body of the successful response, as chunks.
  /// - Throws: ``TransportError/httpStatus(body:code:headers:)`` carrying at most the first 64 KiB
  ///   of the body for a status outside `2xx`, ``TransportError/cancelled`` for a caller cancelled
  ///   at any point up to and including that read, and whatever the transport or the body encoder
  ///   threw. A failure after the sequence is returned surfaces from the sequence itself.
  public func stream(_ request: Request) async throws(TransportError) -> StreamedBody {
    try await openStream(request).body
  }

  /// Returns a sequence of server-sent events that reconnects when the stream ends or fails,
  /// re-issuing the request with `Last-Event-ID`.
  ///
  /// Nothing is sent until the sequence is read. Each connection is a ``stream(_:)`` call, so it
  /// keeps the resolution, the credential rules, and the redirect rules; the wait before each
  /// reconnect is the server's last `retry` field on ``clock``, or `reconnectDelay` until it has
  /// sent one. See ``EventSource`` for when the sequence reconnects and when it ends.
  ///
  /// ```swift
  /// for try await event in client.events(Request(path: "/events")) {
  ///   handle(event)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - request: The request each connection sends, relative to ``baseURL``.
  ///   - maxLineLength: The most bytes a single line may carry, or `nil` for no limit.
  ///   - reconnectDelay: The wait before a reconnect until the server has sent a `retry` field;
  ///     three seconds by default, which is what browsers wait.
  /// - Returns: The events, across every connection, as an ``EventSource``.
  public func events(
    _ request: Request, maxLineLength: Int? = nil, reconnectDelay: Duration = .seconds(3)
  ) -> EventSource {
    EventSource(
      client: self, maxLineLength: maxLineLength, reconnectDelay: reconnectDelay, request: request)
  }

  /// Sends the request and returns its successful response with the body still arriving.
  ///
  /// This is ``stream(_:)`` with the status and the header fields kept: ``stream(_:)`` returns the
  /// body alone, and ``EventSource`` needs the status to tell a `204` from a stream to read.
  ///
  /// - Parameter request: The request, relative to ``baseURL``.
  /// - Returns: The successful response, its status and header fields settled and its body as
  ///   chunks.
  /// - Throws: What ``stream(_:)`` throws.
  func openStream(_ request: Request) async throws(TransportError) -> StreamedResponse {
    let resolved = try resolve(request)
    let response = try await exchange(
      resolved, number: 1, redirects: request.options.redirectPolicy ?? redirectPolicy,
      requiresAuth: request.options.requiresAuth
    ) { (target, body, options) async throws(TransportError) in
      try await transport.stream(target, body: body, options: options)
    }
    // The status is settled before any chunk is delivered, so what the server said about the
    // failure is read this far and no further, and the body is released with the throw, which
    // stops the fetch.
    guard response.status.kind == .successful else {
      let body = await errorBody(response.body)
      // A caller cancelled during the read asked to leave, and the status is not what it is
      // waiting to hear; the read ends the same way and the answer is the cancellation.
      if Task.isCancelled { throw .cancelled }
      throw .httpStatus(body: body, code: response.status.code, headers: response.headers)
    }
    // The body's end is the caller's to reach, so it is reported from the caller's own read; the
    // transport's task never runs an observer.
    guard let observer else { return response }
    let correlationID = resolved.correlationID
    var reported = response
    reported.body = response.body.reportingEnd { bytesReceived, failure in
      observer.didFinishBody(
        BodyEvent(bytesReceived: bytesReceived, correlationID: correlationID, failure: failure))
    }
    return reported
  }
}

extension Clock where Duration == Swift.Duration {
  /// Runs `work` and returns what it produced together with how long it took on this clock.
  ///
  /// This lives on `Clock` rather than on the client because the client holds its clock as
  /// `any Clock<Duration>`. Calling a method on the existential opens it, so the instant arithmetic
  /// here runs on the clock's own instant type, which the existential does not expose.
  fileprivate func timed<Answer>(
    _ work: () async throws(TransportError) -> Answer
  ) async -> (duration: Duration, outcome: Result<Answer, TransportError>) {
    let started = now
    let outcome: Result<Answer, TransportError>
    do throws(TransportError) {
      outcome = .success(try await work())
    } catch {
      outcome = .failure(error)
    }
    return (started.duration(to: now), outcome)
  }

  /// Returns a function that reports how much time has passed on this clock since this call.
  ///
  /// The instant is captured here for the reason `timed(_:)` lives here: the client cannot hold one
  /// of the existential's instants, but a closure over the opened clock can.
  fileprivate func stopwatch() -> () -> Duration {
    let started = now
    return { started.duration(to: now) }
  }
}

/// What the client's pipeline needs to know about an answer, whichever entry point asked for it.
///
/// The credential rules, the redirect rules, and the observer reporting are written once and read
/// these properties from a buffered response and a streamed one alike.
private protocol ExchangeAnswer {
  /// The header fields the server answered with.
  var headers: HTTPFields { get }

  /// The bytes an observer may be offered a preview of, or `nil` when the answer holds none.
  var previewableBody: Data? { get }

  /// The status the server answered with.
  var status: HTTPResponse.Status { get }
}

extension Response: ExchangeAnswer {
  fileprivate var previewableBody: Data? { body }
}

extension StreamedResponse: ExchangeAnswer {
  /// None: the body has not arrived, and reading enough of it to preview would consume the stream
  /// the caller asked for.
  fileprivate var previewableBody: Data? { nil }
}
