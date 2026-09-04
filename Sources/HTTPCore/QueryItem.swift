// `URLQueryItem` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// One name and value pair in a request's query string.
///
/// Both sides are stored raw. Percent-encoding happens once, when the query is rendered into a URL,
/// so a value containing `&`, `=`, or `%` is carried without ambiguity and you never have to reason
/// about whether a value has already been escaped.
///
/// ```swift
/// let request = Request(
///   path: "/search",
///   query: [QueryItem(name: "q", value: "tea & coffee"), QueryItem(name: "verbose")]
/// )
/// // Sent as /search?q=tea%20%26%20coffee&verbose
/// ```
public struct QueryItem: Hashable, Sendable {
  /// The parameter name, raw.
  public var name: String

  /// The parameter value, raw.
  ///
  /// A value of `nil` renders the name alone with no `=`, which is distinct from an empty value
  /// that renders as `name=`.
  public var value: String?

  /// Creates a query item from a raw name and an optional raw value.
  ///
  /// - Parameters:
  ///   - name: The parameter name, unencoded.
  ///   - value: The parameter value, unencoded; `nil` for a bare flag.
  public init(name: String, value: String? = nil) {
    self.name = name
    self.value = value
  }

  /// Creates a query item from a `URLQueryItem`, carrying its name and value raw.
  ///
  /// Both sides are taken as written and percent-encoded when the query is rendered, the same as an
  /// item built from a name and value, so an item you already hold as a `URLQueryItem` needs no
  /// re-encoding to be sent. A `URLQueryItem` whose `value` is `nil` becomes a bare flag.
  ///
  /// - Parameter item: The query item to carry.
  public init(_ item: URLQueryItem) {
    self.init(name: item.name, value: item.value)
  }

  /// The item rendered as `name=value`, or as a bare `name` for a `nil` value, with both sides
  /// percent-encoded.
  ///
  /// Every UTF-8 byte outside RFC 3986's unreserved set (`A-Z`, `a-z`, `0-9`, `-`, `.`, `_`, `~`)
  /// becomes `%XX` with uppercase hex. A space is therefore `%20` and never `+`, and a literal `+`
  /// is `%2B`, the one spelling an RFC 3986 decoder and an `application/x-www-form-urlencoded`
  /// decoder read back identically. Input is always treated as raw, so a `%` in the value is a
  /// literal percent sign and encodes to `%25`.
  ///
  /// - Complexity: O(*n*), where *n* is the total UTF-8 length of the name and value.
  public var percentEncoded: String {
    guard let value else { return percentEncode(name) }
    return percentEncode(name) + "=" + percentEncode(value)
  }

  /// The item rendered for an `application/x-www-form-urlencoded` body, as `name=value` or as a
  /// bare `name` for a `nil` value.
  ///
  /// Both sides are encoded by the rule ``percentEncoded`` uses, with one difference: a space is
  /// `+` rather than `%20`, which is what a form decoder reads as a space. A literal `+` stays
  /// `%2B`, so the two can never be confused.
  ///
  /// - Complexity: O(*n*), where *n* is the total UTF-8 length of the name and value.
  package var formEncoded: String {
    guard let value else { return percentEncode(name, spaceAsPlus: true) }
    return percentEncode(name, spaceAsPlus: true) + "=" + percentEncode(value, spaceAsPlus: true)
  }
}

extension Collection<QueryItem> {
  /// The items rendered as a query string.
  ///
  /// Each item's ``QueryItem/percentEncoded`` form, joined with `&` in the collection's order, with
  /// duplicates preserved. Empty when the collection is empty.
  ///
  /// - Complexity: O(*n*), where *n* is the total UTF-8 length of every name and value.
  public var percentEncoded: String {
    joined(rendering: \.percentEncoded)
  }

  /// The items rendered as an `application/x-www-form-urlencoded` body.
  ///
  /// Each item's ``QueryItem/formEncoded`` form, joined with `&` in the collection's order, with
  /// duplicates preserved. Empty when the collection is empty.
  ///
  /// - Complexity: O(*n*), where *n* is the total UTF-8 length of every name and value.
  package var formEncoded: String {
    joined(rendering: \.formEncoded)
  }

  /// Every item rendered by `render`, joined with `&` in the collection's order.
  private func joined(rendering render: (QueryItem) -> String) -> String {
    var rendered = ""
    for (index, item) in enumerated() {
      if index > 0 { rendered.append("&") }
      rendered.append(render(item))
    }
    return rendered
  }
}

/// Percent-encodes every byte of `raw`'s UTF-8 form that is not in RFC 3986's unreserved set.
///
/// Encoding is per byte, so a multi-scalar grapheme encodes as its individual UTF-8 bytes. With
/// `spaceAsPlus`, a space renders as `+` instead of `%20`, the one place an
/// `application/x-www-form-urlencoded` body departs from a query string.
private func percentEncode(_ raw: String, spaceAsPlus: Bool = false) -> String {
  var encoded: [UInt8] = []
  encoded.reserveCapacity(raw.utf8.count)
  for byte in raw.utf8 {
    if isUnreserved(byte) {
      encoded.append(byte)
    } else if spaceAsPlus, byte == UInt8(ascii: " ") {
      encoded.append(UInt8(ascii: "+"))
    } else {
      encoded.append(UInt8(ascii: "%"))
      encoded.append(hexDigit(byte >> 4))
      encoded.append(hexDigit(byte & 0x0F))
    }
  }
  return String(decoding: encoded, as: UTF8.self)
}

/// Whether `byte` is in RFC 3986's unreserved set, the only bytes that pass through unencoded.
private func isUnreserved(_ byte: UInt8) -> Bool {
  switch byte {
  case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
    UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
    UInt8(ascii: "~"):
    return true
  default:
    return false
  }
}

/// The uppercase ASCII hex digit for a nibble in `0...15`. Uppercase is RFC 3986's normal form.
private func hexDigit(_ nibble: UInt8) -> UInt8 {
  nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "A") + nibble - 10
}
