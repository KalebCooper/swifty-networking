/// Where the page after the current one lives, as a ``PageSequence`` is told it.
///
/// An API points at its following page in one of two ways: with a URI reference, most often in a
/// `Link` header field, or with something the client sends back, such as a cursor from the body.
/// The first is ``link(_:)`` and the second is ``request(_:)``.
///
/// ```swift
/// let issues = client.pages(Request(path: "/repos/o/r/issues"), as: [Issue].self) { page, _ in
///   WebLink.links(in: page.headers)
///     .first { $0.relations.contains("next") }
///     .map { .link($0.target) }
/// }
/// ```
public enum NextPage: Sendable {
  /// A URI reference, resolved against the URL the current page was fetched from.
  ///
  /// The reference is resolved the way RFC 3986 resolves a relative reference, against the URL of
  /// the response that carried the page, after any redirect, so a relative target reads the way the
  /// server wrote it. The page is fetched with `GET` and no body, keeping the header fields and
  /// options of the request that produced the current page. `Content-Type` and `Content-Length` are
  /// removed, as on a 303 redirect, and every other header field stays. The request later handed to
  /// ``PageSequence/next`` keeps the path and query of the last request that was not a link, not
  /// this reference.
  ///
  /// A target on another origin is still fetched, but it goes without `Authorization`, `Cookie`,
  /// `Proxy-Authorization`, and the field ``HTTPClient/authentication``'s scheme writes into,
  /// whether you set the field yourself, set it in ``HTTPClient/defaultHeaders``, or the client
  /// attached it, the same rule a redirect to another origin follows. Every other header field
  /// travels as set.
  case link(String)

  /// A request relative to the client's base URL, sent like any other request.
  case request(Request)
}
