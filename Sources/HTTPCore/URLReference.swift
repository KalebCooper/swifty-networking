/// Reference resolution as RFC 3986 defines it in 5.2, over strings.
///
/// A reference is absolute, network-path, absolute-path, relative-path, or query-only, and each of
/// them names exactly one absolute URL once it is read against an absolute base. The work happens
/// on the string, so the rule is the same on every platform: no `URL`, no `URLComponents`, and no
/// normalization of case or of percent-encoding, so what was written is what comes back.
///
/// ```swift
/// URLReference.resolve("../g", against: "http://a/b/c/d;p?q")  // "http://a/b/g"
/// ```
package enum URLReference {
  /// The absolute URL `reference` names when it is read against `base`, or `nil` when `base` is
  /// not absolute.
  ///
  /// The result carries no fragment: one written on either side is dropped, because an HTTP
  /// request target has none. A query the reference writes is kept even when it is empty, so `g?`
  /// resolves with its question mark still on it; only a reference that writes no query at all,
  /// and names no path, inherits the base's.
  ///
  /// ```swift
  /// URLReference.resolve("g", against: "http://a/b/c/d;p?q")      // "http://a/b/c/g"
  /// URLReference.resolve("//example.com/g", against: "http://a")  // "http://example.com/g"
  /// URLReference.resolve("g", against: "/b/c")                    // nil
  /// ```
  ///
  /// - Parameters:
  ///   - reference: The reference to resolve, in any of the forms RFC 3986 allows in 4.2.
  ///   - base: The absolute URL to read `reference` against. It needs a scheme and an authority
  ///     that names a host, so a base that is itself a relative reference is refused, and so is one
  ///     whose authority is empty.
  /// - Returns: The resolved URL, or `nil` when `base` is unusable.
  package static func resolve(_ reference: String, against base: String) -> String? {
    let base = parse(base)
    let reference = parse(reference)
    guard let baseScheme = base.scheme, let baseAuthority = base.authority, !baseAuthority.isEmpty
    else { return nil }

    let authority: String?
    let path: String
    let query: String?
    let scheme = reference.scheme ?? baseScheme

    // RFC 3986 5.2.2. Its first two branches, a reference carrying a scheme and a network-path
    // reference, differ only in where the scheme comes from, which the line above already settled.
    if reference.scheme != nil || reference.authority != nil {
      authority = reference.authority
      path = removingDotSegments(reference.path)
      query = reference.query
    } else if reference.path.isEmpty {
      authority = baseAuthority
      path = base.path
      query = reference.query ?? base.query
    } else if reference.path.hasPrefix("/") {
      authority = baseAuthority
      path = removingDotSegments(reference.path)
      query = reference.query
    } else {
      authority = baseAuthority
      path = removingDotSegments(merging(reference.path, onto: base))
      query = reference.query
    }

    var resolved = scheme
    resolved.append(":")
    if let authority {
      resolved.append("//")
      resolved.append(authority)
    }
    resolved.append(path)
    if let query {
      resolved.append("?")
      resolved.append(query)
    }
    return resolved
  }

  /// `path` merged onto `base`'s path, as RFC 3986 defines the merge in 5.2.3.
  ///
  /// The base's last segment is what a relative path replaces, so everything after its final `/`
  /// is dropped. A base that names an authority and no path contributes the separator instead.
  /// The remaining case, a base path holding no `/` at all, is unreachable from the absolute base
  /// this resolver accepts: a path written after an authority always opens with one.
  private static func merging(_ path: String, onto base: Parts) -> String {
    if base.authority != nil, base.path.isEmpty { return "/" + path }
    guard let lastSeparator = base.path.lastIndex(of: "/") else { return path }
    return String(base.path[...lastSeparator]) + path
  }

  /// `string` split into the four components resolution reads, with any fragment discarded.
  ///
  /// The cuts run in the order the grammar writes the components in, so a delimiter belonging to a
  /// later component can never be mistaken for an earlier one: a `?` inside a fragment is gone
  /// before the query is looked for, and a `:` inside a query or a path is gone before the scheme
  /// is. A component is `nil` when it was not written at all, which is what tells `?` and `//`
  /// apart from their absence.
  ///
  /// ```swift
  /// let parts = URLReference.parse("https://a/b?q")
  /// // parts.scheme == "https", parts.authority == "a", parts.path == "/b", parts.query == "q"
  /// ```
  ///
  /// - Parameter string: A URI or a reference, in any form.
  /// - Returns: The components as written, with nothing normalized.
  package static func parse(_ string: String) -> Parts {
    var rest = Substring(string)
    if let numberSign = rest.firstIndex(of: "#") { rest = rest[..<numberSign] }

    let query: String?
    if let questionMark = rest.firstIndex(of: "?") {
      query = String(rest[rest.index(after: questionMark)...])
      rest = rest[..<questionMark]
    } else {
      query = nil
    }

    let scheme: String?
    if let colon = rest.firstIndex(of: ":"), isScheme(rest[..<colon]) {
      scheme = String(rest[..<colon])
      rest = rest[rest.index(after: colon)...]
    } else {
      scheme = nil
    }

    let authority: String?
    if rest.hasPrefix("//") {
      let afterSeparator = rest.dropFirst(2)
      let authorityEnd = afterSeparator.firstIndex(of: "/") ?? afterSeparator.endIndex
      authority = String(afterSeparator[..<authorityEnd])
      rest = afterSeparator[authorityEnd...]
    } else {
      authority = nil
    }

    return Parts(authority: authority, path: String(rest), query: query, scheme: scheme)
  }

  /// `path` with its `.` and `..` segments resolved away, as RFC 3986 defines the removal in 5.2.4.
  ///
  /// A `..` that would climb above the root is discarded rather than kept, so the result can never
  /// reach outside the authority it belongs to.
  private static func removingDotSegments(_ path: String) -> String {
    var input = Substring(path)
    var output = ""
    while !input.isEmpty {
      if input.hasPrefix("../") {
        input = input.dropFirst(3)
      } else if input.hasPrefix("./") {
        input = input.dropFirst(2)
      } else if input.hasPrefix("/./") {
        input = input.dropFirst(2)
      } else if input == "/." {
        input = "/"
      } else if input.hasPrefix("/../") {
        input = input.dropFirst(3)
        removeLastSegment(from: &output)
      } else if input == "/.." {
        input = "/"
        removeLastSegment(from: &output)
      } else if input == "." || input == ".." {
        input = ""
      } else {
        // One segment moves across whole, taking any leading separator with it, so the separator
        // is never read as the start of the next segment.
        let afterSeparator =
          input.hasPrefix("/") ? input.index(after: input.startIndex) : input.startIndex
        let segmentEnd = input[afterSeparator...].firstIndex(of: "/") ?? input.endIndex
        output.append(contentsOf: input[..<segmentEnd])
        input = input[segmentEnd...]
      }
    }
    return output
  }

  /// Removes `output`'s last segment and the separator in front of it, leaving nothing when it
  /// held a single segment.
  private static func removeLastSegment(from output: inout String) {
    guard let lastSeparator = output.lastIndex(of: "/") else {
      output = ""
      return
    }
    output = String(output[..<lastSeparator])
  }

  /// Whether `candidate` is a scheme: RFC 3986's `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`.
  ///
  /// The leading letter is what keeps a colon inside a relative path from reading as a scheme.
  private static func isScheme(_ candidate: Substring) -> Bool {
    guard let first = candidate.first, first.isASCII, first.isLetter else { return false }
    return candidate.dropFirst().allSatisfy { character in
      character.isASCII && (character.isLetter || character.isNumber || "+-.".contains(character))
    }
  }

  /// The components of a URI or a reference, each `nil` when it was not written.
  package struct Parts {
    /// The authority, without its `//`.
    package var authority: String?

    /// The path, empty when there is none. Always written, never absent.
    package var path: String

    /// The query exactly as written, without its `?`.
    package var query: String?

    /// The scheme, without its `:`.
    package var scheme: String?
  }

  /// The scheme, host, and port that decide whether two URLs share an origin.
  ///
  /// Two origins are equal as RFC 6454 compares them: the scheme and the host without regard to
  /// case, and the port as written or, when none was, the scheme's default, `80` for `http` and
  /// `443` for `https`. So `HTTP://A:80/x` and `http://a/y` are one origin, and `https://a` and
  /// `https://a:8443` are two. A scheme without a known default and no written port compares
  /// on scheme and host alone.
  ///
  /// ```swift
  /// let origin = URLReference.Origin(authority: "API.example.com", scheme: "https")
  /// // origin == URLReference.Origin(authority: "api.example.com:443", scheme: "HTTPS")
  /// ```
  package struct Origin: Hashable, Sendable {
    /// The host, lowercased, with its brackets when it is an IPv6 literal.
    package var host: String

    /// The port as written, or the scheme's default when none was or the port was left empty
    /// after its colon; `nil` when the scheme has no default, or when what was written is not a
    /// number.
    package var port: Int?

    /// The scheme, lowercased.
    package var scheme: String

    /// Creates the origin of a URL from its scheme and authority, or returns `nil` when either
    /// names nothing.
    ///
    /// Any userinfo ahead of the last `@` is discarded: it is a credential, not part of the
    /// origin. A bracketed IPv6 host is kept whole, so the colons inside it are never read as a
    /// port separator.
    ///
    /// - Parameters:
    ///   - authority: The authority as written, without its `//`.
    ///   - scheme: The scheme as written, without its `:`.
    package init?(authority: String?, scheme: String?) {
      guard let scheme, !scheme.isEmpty, let authority else { return nil }
      var hostAndPort = Substring(authority)
      if let at = hostAndPort.lastIndex(of: "@") {
        hostAndPort = hostAndPort[hostAndPort.index(after: at)...]
      }

      let host: Substring
      let writtenPort: Substring?
      if hostAndPort.hasPrefix("["), let closing = hostAndPort.firstIndex(of: "]") {
        host = hostAndPort[...closing]
        let rest = hostAndPort[hostAndPort.index(after: closing)...]
        writtenPort = rest.hasPrefix(":") ? rest.dropFirst() : nil
      } else if let colon = hostAndPort.lastIndex(of: ":") {
        host = hostAndPort[..<colon]
        writtenPort = hostAndPort[hostAndPort.index(after: colon)...]
      } else {
        host = hostAndPort
        writtenPort = nil
      }
      guard !host.isEmpty else { return nil }

      self.host = host.lowercased()
      self.scheme = scheme.lowercased()
      // RFC 3986 3.2.3: a colon with nothing after it means the scheme's default port.
      if let writtenPort, !writtenPort.isEmpty {
        port = Int(writtenPort)
      } else {
        port =
          switch self.scheme {
          case "http": 80
          case "https": 443
          default: nil
          }
      }
    }
  }
}
