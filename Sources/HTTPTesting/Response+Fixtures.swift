// `Data` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPCore
import HTTPTypes

extension Response {
  /// Returns a response with no body, `204 No Content` by default.
  ///
  /// - Parameters:
  ///   - headers: Header fields; defaults to none.
  ///   - status: The response status; defaults to `.noContent`.
  /// - Returns: The response.
  public static func empty(headers: HTTPFields = [:], status: HTTPResponse.Status = .noContent)
    -> Response
  {
    Response(body: Data(), headers: headers, status: status)
  }

  /// Returns a response whose body is JSON.
  ///
  /// The response carries `Content-Type: application/json`, unless `headers` already sets a
  /// `Content-Type` of its own.
  ///
  /// ```swift
  /// let response = Response.json(
  ///   Fixtures.jsonObject(["message": "Not found"]),
  ///   status: .notFound
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - body: The JSON bytes, most often from ``Fixtures``.
  ///   - headers: Header fields the derived `Content-Type` is added to; defaults to none.
  ///   - status: The response status.
  /// - Returns: The response.
  public static func json(_ body: Data, headers: HTTPFields = [:], status: HTTPResponse.Status)
    -> Response
  {
    var headers = headers
    if headers[.contentType] == nil {
      headers[.contentType] = "application/json"
    }
    return Response(body: body, headers: headers, status: status)
  }

  /// Returns a `200 OK` response whose body is JSON.
  ///
  /// The response carries `Content-Type: application/json`, unless `headers` already sets a
  /// `Content-Type` of its own.
  ///
  /// - Parameters:
  ///   - headers: Header fields the derived `Content-Type` is added to; defaults to none.
  ///   - body: The JSON bytes, most often from ``Fixtures``.
  /// - Returns: The response.
  public static func ok(headers: HTTPFields = [:], json body: Data) -> Response {
    .json(body, headers: headers, status: .ok)
  }

  /// Returns a response whose body is plain text.
  ///
  /// The response carries `Content-Type: text/plain; charset=utf-8`, unless `headers` already sets
  /// a `Content-Type` of its own.
  ///
  /// - Parameters:
  ///   - string: The text, encoded as UTF-8.
  ///   - headers: Header fields the derived `Content-Type` is added to; defaults to none.
  ///   - status: The response status; defaults to `.ok`.
  /// - Returns: The response.
  public static func text(
    _ string: String, headers: HTTPFields = [:], status: HTTPResponse.Status = .ok
  ) -> Response {
    var headers = headers
    if headers[.contentType] == nil {
      headers[.contentType] = "text/plain; charset=utf-8"
    }
    return Response(body: Data(string.utf8), headers: headers, status: status)
  }
}
