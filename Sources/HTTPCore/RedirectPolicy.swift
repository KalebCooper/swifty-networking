/// What a client does with a `3xx` response that names a `Location`.
///
/// A transport never follows a redirect; it returns the `3xx` like any other response, and
/// ``HTTPClient`` decides whether to send the request again to the target the `Location` field
/// names. The client's ``HTTPClient/redirectPolicy`` applies to every request, and a request's own
/// ``RequestOptions/redirectPolicy`` takes its place when set.
///
/// ```swift
/// let request = Request(
///   options: RequestOptions(redirectPolicy: .never),
///   path: "/download"
/// )
/// ```
///
/// A redirect the policy does not follow is returned as the response it was, so every entry point
/// throws it as ``TransportError/httpStatus(body:code:headers:)`` with the `Location` field still
/// in `headers`.
public enum RedirectPolicy: Hashable, Sendable {
  /// Follow every redirect, to any origin.
  ///
  /// A hop to another origin goes out without the credential the client attached, so a token
  /// meant for one host never reaches another.
  case follow

  /// Follow no redirect: every `3xx` is returned as the response.
  case never

  /// Follow a redirect only when its target has the scheme, host, and port the request was sent
  /// to; a hop anywhere else returns the `3xx`.
  case sameOrigin
}
