/// The pieces of a client's base URL, split once so that joining a request onto it is a
/// concatenation.
///
/// The accepted grammar is `scheme://authority[/path][?query]`. Parsing is by hand so that the join
/// follows one rule on every platform: a `URL` reaches here as its `absoluteString`, and neither
/// Foundation's path-appending nor its query encoding takes part. A fragment is refused: an HTTP
/// request target has no fragment, so a base written with one is a mistake.
struct BaseURL: Hashable, Sendable {
  /// The host, with a port when one was written.
  var authority: String

  /// The base path with any trailing `/` removed; empty when the base names only a scheme and
  /// authority.
  ///
  /// Stripping the trailing slash leaves the join one rule: the request path supplies the
  /// separator. `https://h/v1/` and `https://h/v1` mean the same thing.
  var path: String

  /// The base query exactly as written, without its `?`; `nil` when there is none.
  ///
  /// It is kept verbatim. Whoever wrote the base already encoded it, and encoding it again would
  /// turn every `=` and `&` into a literal.
  var query: String?

  /// The scheme, without the `://`.
  var scheme: String

  /// Parses `string`, or returns `nil` when it is not a usable base.
  ///
  /// Refused: a missing `://`, an empty scheme, a scheme containing anything but letters, digits,
  /// `+`, `-`, or `.`, an empty authority, and a `#` anywhere.
  init?(_ string: String) {
    guard !string.contains("#"), let schemeEnd = string.firstIndex(of: ":") else { return nil }
    let scheme = string[..<schemeEnd]
    guard !scheme.isEmpty, scheme.allSatisfy(Self.isSchemeCharacter) else { return nil }

    let afterScheme = string[string.index(after: schemeEnd)...]
    guard afterScheme.hasPrefix("//") else { return nil }
    let afterSeparator = afterScheme.dropFirst(2)

    let authorityEnd =
      afterSeparator.firstIndex { $0 == "/" || $0 == "?" } ?? afterSeparator.endIndex
    let authority = afterSeparator[..<authorityEnd]
    guard !authority.isEmpty else { return nil }

    let tail = afterSeparator[authorityEnd...]
    let rawPath: Substring
    let rawQuery: Substring?
    if let queryStart = tail.firstIndex(of: "?") {
      rawPath = tail[..<queryStart]
      rawQuery = tail[tail.index(after: queryStart)...]
    } else {
      rawPath = tail
      rawQuery = nil
    }

    var path = rawPath
    while path.hasSuffix("/") { path = path.dropLast() }

    self.authority = String(authority)
    self.path = String(path)
    self.query = rawQuery.flatMap { $0.isEmpty ? nil : String($0) }
    self.scheme = String(scheme)
  }

  /// The request target for `path` joined onto this base, with `query` rendered and appended.
  ///
  /// The request path is appended, never substituted. A leading `/` is supplied when it is missing,
  /// an empty path resolves to the base itself, and the result is never empty, because a request
  /// target cannot be. The base's own query comes first, then the request's items, percent-encoded
  /// here and nowhere else.
  ///
  /// - Parameters:
  ///   - path: The request's path, relative to this base.
  ///   - query: The request's query items, in the order they are rendered.
  /// - Returns: The `:path` pseudo-header value, path and query together.
  func target(path: String, query: [QueryItem]) -> String {
    var target = self.path
    if !path.isEmpty {
      if !path.hasPrefix("/") { target.append("/") }
      target.append(path)
    }
    if target.isEmpty { target = "/" }

    var queryString = self.query ?? ""
    let requestQuery = query.percentEncoded
    if !requestQuery.isEmpty {
      if !queryString.isEmpty { queryString.append("&") }
      queryString.append(requestQuery)
    }
    if !queryString.isEmpty {
      target.append("?")
      target.append(queryString)
    }
    return target
  }

  /// Whether `character` may appear in a scheme: RFC 3986's `ALPHA / DIGIT / "+" / "-" / "."`.
  private static func isSchemeCharacter(_ character: Character) -> Bool {
    character.isASCII && (character.isLetter || character.isNumber || "+-.".contains(character))
  }
}
