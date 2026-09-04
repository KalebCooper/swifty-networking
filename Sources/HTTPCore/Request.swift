import HTTPTypes

/// A request described relative to a client's base URL.
///
/// A request carries a method, a path, query items, header fields, a body, and the per-request
/// policy settings in ``RequestOptions``. The path and query stay separate from any absolute URL:
/// the client owns the base URL and joins them at send time, so the same request value can be sent
/// to another host by another client, and describing a request needs no Foundation URL type.
///
/// ```swift
/// let request = Request(
///   body: .json(SignUp(email: "person@example.com")),
///   method: .post,
///   path: "/profiles",
///   query: [QueryItem(name: "notify", value: "false")]
/// )
/// let profile: Profile = try await client.execute(request)
/// ```
public struct Request: Sendable {
  /// The payload to send; ``RequestBody/none`` for a body-less request.
  public var body: RequestBody

  /// Header fields sent with this request, layered over the client's defaults.
  public var headers: HTTPFields

  /// The HTTP method.
  public var method: HTTPRequest.Method

  /// Per-request policy settings.
  public var options: RequestOptions

  /// The path relative to the client's base URL, sent as written.
  ///
  /// Percent-encode a path segment yourself when it needs it: path rules differ from query rules,
  /// and the client encodes only the query.
  public var path: String

  /// Query items appended to the path, percent-encoded at send time in this order.
  public var query: [QueryItem]

  /// Creates a request.
  ///
  /// - Parameters:
  ///   - body: The payload; defaults to ``RequestBody/none``.
  ///   - headers: Header fields for this request; defaults to none.
  ///   - method: The HTTP method; defaults to `GET`.
  ///   - options: Per-request policy settings; defaults to `RequestOptions()`.
  ///   - path: The path relative to the client's base URL.
  ///   - query: Query items; defaults to none.
  public init(
    body: RequestBody = .none,
    headers: HTTPFields = [:],
    method: HTTPRequest.Method = .get,
    options: RequestOptions = RequestOptions(),
    path: String,
    query: [QueryItem] = []
  ) {
    self.body = body
    self.headers = headers
    self.method = method
    self.options = options
    self.path = path
    self.query = query
  }
}
