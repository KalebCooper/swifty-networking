import HTTPTypes

/// A decoded body together with the header fields and status it arrived with.
///
/// Annotating an `execute(_:)` call with this type answers with the response's metadata when it is
/// part of the answer rather than a detail of transporting it: an `ETag` to send back on the next
/// request, a rate-limit budget, a pagination cursor. The body is decoded exactly as
/// ``HTTPClient/execute(_:)->R`` decodes it, so a large one still parses off the caller's executor.
///
/// ```swift
/// let page: DecodedResponse<[Item]> = try await client.execute(Request(path: "/items"))
/// print(page.value.count, page.headers[.eTag] ?? "", page.status.code)
/// ```
public struct DecodedResponse<Value> {
  /// The response header fields.
  public var headers: HTTPFields

  /// The response status.
  public var status: HTTPResponse.Status

  /// The decoded body.
  public var value: Value

  /// Creates a decoded response.
  ///
  /// - Parameters:
  ///   - headers: The response header fields.
  ///   - status: The response status.
  ///   - value: The decoded body.
  public init(headers: HTTPFields, status: HTTPResponse.Status, value: Value) {
    self.headers = headers
    self.status = status
    self.value = value
  }
}

extension DecodedResponse: Sendable where Value: Sendable {}
