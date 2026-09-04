import HTTPTypes

/// A response whose body has not been read: status, header fields, and the bytes still arriving.
///
/// This is the streaming counterpart to ``Response``. ``Response/body`` is `Data`, a fully buffered
/// value, and a stream has no such value to offer until it has ended, which is what a caller
/// streaming a response is trying not to wait for. Everything else about the two is the same: the
/// status is reported as the server sent it, with nothing interpreted, and the header fields are
/// complete, because a response's fields arrive before its body.
///
/// ```swift
/// let answer = try await transport.stream(request, body: .none, options: TransportOptions())
/// guard answer.status.kind == .successful else { throw MyError.refused(answer.status.code) }
/// for try await chunk in answer.body { handle(chunk) }
/// ```
///
/// The body is a ``StreamedBody``, so a transport wraps its own chunk sequence once, through
/// ``StreamedBody/init(_:mapFailure:)``, and every caller reads the same non-generic type.
public struct StreamedResponse: Sendable {
  /// The response body, delivered a chunk at a time as it arrives.
  public var body: StreamedBody

  /// The response header fields, complete: they arrive ahead of the body.
  public var headers: HTTPFields

  /// The response status, as the server sent it.
  public var status: HTTPResponse.Status

  /// Creates a streamed response.
  ///
  /// - Parameters:
  ///   - body: The chunks of the body, still arriving.
  ///   - headers: The response header fields.
  ///   - status: The response status.
  public init(body: StreamedBody, headers: HTTPFields, status: HTTPResponse.Status) {
    self.body = body
    self.headers = headers
    self.status = status
  }
}
