// `Data` and `JSONEncoder` are the only Foundation types this file needs. The iOS SDK ships no
// separate FoundationEssentials module, so full Foundation is imported where that is the only
// option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// JSON bytes for the body of a canned response, built without a `JSONEncoder` of your own.
///
/// Every member is `static`, so the type is a namespace and is never instantiated. Pass what these
/// methods return to `Response.json(_:headers:status:)` or `Response.ok(headers:json:)`.
///
/// ```swift
/// let transport = MockTransport(results: [
///   .success(.ok(json: Fixtures.jsonObject(["id": "42", "name": "Ada"])))
/// ])
/// ```
public enum Fixtures {
  /// Encodes a value as JSON with sorted keys.
  ///
  /// Sorted keys make the bytes stable, so the same value always encodes identically and a fixture
  /// can be compared byte for byte.
  ///
  /// - Parameter object: The value to encode.
  /// - Returns: The encoded JSON.
  /// - Throws: Whatever `JSONEncoder` throws for a value it cannot represent.
  public static func json(_ object: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(object)
  }

  /// Builds the bytes of a flat JSON object from string-valued pairs.
  ///
  /// Use it for a fixture too small to warrant an `Encodable` type of its own. The pairs are
  /// written in the order given, and both keys and values are escaped as JSON strings.
  ///
  /// - Parameter pairs: The object's key/value pairs, written to the output in this order.
  /// - Returns: The object's JSON bytes.
  public static func jsonObject(_ pairs: KeyValuePairs<String, String>) -> Data {
    var text = "{"
    for (offset, pair) in pairs.enumerated() {
      if offset > 0 { text += "," }
      text += "\"\(escaped(pair.key))\":\"\(escaped(pair.value))\""
    }
    text += "}"
    return Data(text.utf8)
  }

  /// Escapes the characters JSON requires inside a string literal.
  private static func escaped(_ string: String) -> String {
    var result = ""
    for character in string {
      switch character {
      case "\"":
        result += "\\\""
      case "\\":
        result += "\\\\"
      case "\n":
        result += "\\n"
      case "\r":
        result += "\\r"
      case "\t":
        result += "\\t"
      default:
        result.append(character)
      }
    }
    return result
  }
}
