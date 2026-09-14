import HTTPTypes

/// One link from a `Link` header field, as RFC 8288 defines it.
///
/// A `Link` field lists links, each a target URI reference in angle brackets followed by parameters
/// that describe it. The `rel` parameter names how the target relates to the response, so an API
/// that pages its results points at the following page with `rel="next"`:
///
/// ```swift
/// func nextPageTarget(of response: Response) -> String? {
///   WebLink.links(in: response.headers)
///     .first { $0.relations.contains("next") }?
///     .target
/// }
/// ```
///
/// The target is returned as written. ``NextPage/link(_:)`` resolves a relative reference against
/// the URL of the response that carried it.
public struct WebLink: Hashable, Sendable {
  /// The link's parameters, keyed by lowercased name.
  ///
  /// Names compare case-insensitively, so each one is stored lowercased. When a name appears more
  /// than once in a link, the first occurrence is kept and the rest are ignored, the rule RFC 8288
  /// gives for `rel`. A quoted value is stored without its quotes and with each backslash escape
  /// replaced by the character it escapes. A parameter written without a value is stored as the
  /// empty string.
  ///
  /// The `rel` parameter is kept here as written, in addition to ``relations``. Extended parameters
  /// such as `title*` are stored raw under their lowercased name, not decoded.
  public var parameters: [String: String]

  /// The link's relation types, lowercased, in the order its `rel` parameter lists them.
  ///
  /// The `rel` value is split on spaces and tabs, so `rel="next last"` gives `["next", "last"]`.
  /// RFC 8288 compares relation types case-insensitively, registered types and extension type URIs
  /// alike, so each one is lowercased. A link without a `rel` parameter has no relations.
  public var relations: [String]

  /// The link's target URI reference, exactly as written between the angle brackets.
  public var target: String

  /// Creates a link from its parameters, relation types, and target.
  ///
  /// - Parameters:
  ///   - parameters: The link's parameters, keyed by lowercased name.
  ///   - relations: The link's relation types, lowercased.
  ///   - target: The link's target URI reference.
  public init(parameters: [String: String], relations: [String], target: String) {
    self.parameters = parameters
    self.relations = relations
    self.target = target
  }

  /// Returns every link in the `Link` fields of a set of header fields, in the order they appear.
  ///
  /// Each `Link` field is read in turn, and each link within a field in order. A link that does not
  /// follow the RFC 8288 grammar is skipped, and reading resumes at the next link in the same field.
  /// A quoted value that never closes ends its field, and the fields after it are still read.
  ///
  /// ```swift
  /// let links = WebLink.links(in: response.headers)
  /// let last = links.first { $0.relations.contains("last") }
  /// ```
  ///
  /// - Parameter fields: The header fields to read the `Link` fields from.
  /// - Returns: The links, or an empty array when there is no `Link` field.
  public static func links(in fields: HTTPFields) -> [WebLink] {
    guard let linkField else { return [] }
    return fields[values: linkField].flatMap { value in
      var parser = LinkParser(bytes: Array(value.utf8))
      return parser.links()
    }
  }
}

/// The `Link` header field.
///
/// `HTTPField.Name.init(_:)` is failable because it refuses a character a field name cannot carry,
/// and this name has none; it is optional here only because the initializer is.
private let linkField = HTTPField.Name("Link")

/// Reads the links in one `Link` field value.
///
/// The grammar is the one RFC 8288 gives the `Link` field, over the list syntax of RFC 9110:
///
/// ```
/// Link       = #link-value
/// link-value = "<" URI-Reference ">" *( OWS ";" OWS link-param )
/// link-param = token BWS [ "=" BWS ( token / quoted-string ) ]
/// ```
private struct LinkParser {
  let bytes: [UInt8]
  var index = 0

  private static let backslash = UInt8(ascii: "\\")
  private static let comma = UInt8(ascii: ",")
  private static let quote = UInt8(ascii: "\"")

  /// The byte at the read position, or `nil` at the end of the value.
  private var current: UInt8? {
    index < bytes.count ? bytes[index] : nil
  }

  /// Reads every link in the value, skipping empty list elements and links that break the grammar.
  mutating func links() -> [WebLink] {
    var links: [WebLink] = []
    while true {
      skipWhitespace()
      guard let byte = current else { return links }
      if byte == Self.comma {
        index += 1
      } else if let link = link() {
        links.append(link)
      } else {
        skipPastComma()
      }
    }
  }

  /// Reads one link-value, ending past the comma that closes it or at the end of the value.
  ///
  /// Returns `nil` with the read position where the grammar broke. A target that reaches another
  /// `<` or the end of the value before its `>` never closed, so the position goes back to just
  /// inside its `<`, and a comma it ran over still ends the malformed link.
  private mutating func link() -> WebLink? {
    guard current == UInt8(ascii: "<") else { return nil }
    index += 1
    let start = index
    while let byte = current, byte != UInt8(ascii: ">"), byte != UInt8(ascii: "<") {
      index += 1
    }
    guard current == UInt8(ascii: ">") else {
      index = start
      return nil
    }
    let target = String(decoding: bytes[start..<index], as: UTF8.self)
    index += 1

    var parameters: [String: String] = [:]
    while true {
      skipWhitespace()
      guard let byte = current else { break }
      if byte == Self.comma {
        index += 1
        break
      }
      guard byte == UInt8(ascii: ";") else { return nil }
      index += 1
      guard let parameter = parameter() else { return nil }
      if parameters[parameter.name] == nil {
        parameters[parameter.name] = parameter.value
      }
    }

    let relations = parameters["rel", default: ""]
      .split { $0 == " " || $0 == "\t" }
      .map { $0.lowercased() }
    return WebLink(parameters: parameters, relations: relations, target: target)
  }

  /// Reads one link-param after its semicolon, with its name lowercased.
  private mutating func parameter() -> (name: String, value: String)? {
    skipWhitespace()
    guard let name = token()?.lowercased() else { return nil }
    skipWhitespace()
    guard current == UInt8(ascii: "=") else { return (name, "") }
    index += 1
    skipWhitespace()
    guard let value = current == Self.quote ? quotedString() : token() else { return nil }
    return (name, value)
  }

  /// Reads a quoted-string, dropping its quotes and each backslash that escapes the byte after it.
  ///
  /// Returns `nil` when the value ends before the closing quote.
  private mutating func quotedString() -> String? {
    index += 1
    var value: [UInt8] = []
    while let byte = current {
      index += 1
      if byte == Self.quote {
        return String(decoding: value, as: UTF8.self)
      }
      if byte == Self.backslash {
        guard let escaped = current else { return nil }
        index += 1
        value.append(escaped)
      } else {
        value.append(byte)
      }
    }
    return nil
  }

  /// Moves past the next comma outside a quoted string, or to the end of the value.
  private mutating func skipPastComma() {
    var quoted = false
    while let byte = current {
      index += 1
      if quoted {
        if byte == Self.backslash {
          index += 1
        } else if byte == Self.quote {
          quoted = false
        }
      } else if byte == Self.quote {
        quoted = true
      } else if byte == Self.comma {
        return
      }
    }
  }

  /// Moves past spaces and tabs.
  private mutating func skipWhitespace() {
    while let byte = current, byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") {
      index += 1
    }
  }

  /// Reads a token, or returns `nil` when none starts at the read position.
  private mutating func token() -> String? {
    let start = index
    while let byte = current, Self.isTokenByte(byte) {
      index += 1
    }
    guard index > start else { return nil }
    return String(decoding: bytes[start..<index], as: UTF8.self)
  }

  /// Whether a byte is a `tchar`, a character RFC 9110 allows in a token.
  private static func isTokenByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
      UInt8(ascii: "a")...UInt8(ascii: "z"):
      true
    default:
      "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
  }
}
