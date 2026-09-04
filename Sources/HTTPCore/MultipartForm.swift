// `Data` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A `multipart/form-data` body of text fields and files, assembled one part at a time.
///
/// A form encodes as it is built and holds the result in memory, so every byte a part carries stays
/// in the value until the request is sent. A large upload belongs in
/// ``RequestBody/file(_:contentType:)``, which the transport reads from disk as it sends. Parts go
/// on the wire in the order they were appended, framed by the form's ``boundary``, and the request
/// carries `multipart/form-data` naming that boundary.
///
/// Because the boundary belongs to the form rather than to the request's header fields, this media
/// type replaces a `Content-Type` the request or the client's default header fields carry. It is
/// the one body that does: a field written by hand cannot name the boundary the form settles on.
///
/// A quotation mark or a line break in a `name` or a `filename` is written as `%22`, `%0D`, or
/// `%0A`, which is what keeps it inside the quoted string it sits in, and a line break in a part's
/// `contentType` is escaped the same way, since it would otherwise end the part's header block
/// early. Every other character, one outside ASCII included, is written as its UTF-8 bytes, and a
/// part's payload is written untouched.
///
/// A form with no parts encodes to the closing delimiter alone. RFC 2046's grammar asks for at
/// least one part, so a server may refuse it; sending an empty form is a decision, not an accident
/// this type reports.
///
/// ```swift
/// var form = MultipartForm()
/// form.append(name: "caption", value: "On the trail")
/// form.append(contentType: "image/jpeg", data: photo, filename: "trail.jpg", name: "photo")
///
/// try await client.executeExpectingNoContent(
///   Request(body: .multipart(form), method: .post, path: "/photos")
/// )
/// ```
public struct MultipartForm: Sendable {
  /// The delimiter written before each part and, doubled, at the end of the body.
  ///
  /// ``init()`` mints one: 32 characters drawn at random from the ASCII letters and digits, short
  /// enough to read in a log and long enough that a part's bytes are not expected to contain it.
  /// A boundary passed to ``init(boundary:)`` carries no such property and is used exactly as
  /// given, since it is written into the media type unquoted and between the parts unescaped.
  public let boundary: String

  /// Every part appended so far, each already framed by its delimiter and header fields. The
  /// closing delimiter is not here: ``encoded`` adds it, so a form stays appendable.
  private var parts: Data

  /// Creates a form with no parts, under a boundary it draws for itself.
  ///
  /// ```swift
  /// var form = MultipartForm()
  /// ```
  public init() {
    self.init(boundary: MultipartForm.generatedBoundary())
  }

  /// Creates a form with no parts, under the boundary you name.
  ///
  /// The boundary is used exactly as given: nothing validates it, escapes it, or checks that a
  /// part's bytes avoid it. Reach for this where the bytes have to be predictable, as a test's
  /// expectation does, and for ``init()`` everywhere else.
  ///
  /// - Parameter boundary: The delimiter between parts. Give a value drawn from RFC 2046's
  ///   boundary characters that the parts cannot contain.
  public init(boundary: String) {
    self.boundary = boundary
    self.parts = Data()
  }

  /// Appends a file.
  ///
  /// The part names the file alongside the field and states its own media type. `data` is written
  /// verbatim, so bytes that are not text go out unchanged.
  ///
  /// ```swift
  /// form.append(contentType: "image/jpeg", data: photo, filename: "trail.jpg", name: "photo")
  /// ```
  ///
  /// - Parameters:
  ///   - contentType: The media type of `data`, written into the part's `Content-Type` field. A
  ///     line break in it is percent-encoded, so it cannot end the part's header block early;
  ///     everything else is written as given.
  ///   - data: The file's bytes.
  ///   - filename: The name the server records the file under.
  ///   - name: The field name the server reads the part by.
  public mutating func append(contentType: String, data: Data, filename: String, name: String) {
    write(
      data,
      contentType: escaped(contentType),
      disposition:
        "name=\"\(escaped(name, quotes: true))\"; filename=\"\(escaped(filename, quotes: true))\""
    )
  }

  /// Appends a text field.
  ///
  /// The part carries no media type of its own, which a server reads as `text/plain`, and `value`
  /// is written as its UTF-8 bytes.
  ///
  /// ```swift
  /// form.append(name: "caption", value: "On the trail")
  /// ```
  ///
  /// - Parameters:
  ///   - name: The field name the server reads the part by.
  ///   - value: The field's text.
  public mutating func append(name: String, value: String) {
    write(
      Data(value.utf8), contentType: nil, disposition: "name=\"\(escaped(name, quotes: true))\"")
  }

  /// The media type the body is sent under, the boundary named in it.
  package var contentType: String {
    "multipart/form-data; boundary=\(boundary)"
  }

  /// The parts appended so far followed by the closing delimiter: the body as it goes on the wire.
  package var encoded: Data {
    var body = parts
    body.append(contentsOf: "--\(boundary)--\r\n".utf8)
    return body
  }

  /// A boundary of 32 characters drawn at random from the ASCII letters and digits, what ``init()``
  /// gives a form.
  ///
  /// Every character is one RFC 2046 allows in a boundary and none of them needs quoting in the
  /// media type. The draw is from `SystemRandomNumberGenerator`, so a form mints its boundary the
  /// same way on every platform.
  static func generatedBoundary() -> String {
    var characters: [UInt8] = []
    characters.reserveCapacity(boundaryLength)
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<boundaryLength {
      characters.append(
        boundaryAlphabet[Int.random(in: boundaryAlphabet.indices, using: &generator)])
    }
    return String(decoding: characters, as: UTF8.self)
  }

  /// Writes one part: its delimiter, `Content-Disposition`, the `Content-Type` a file part states,
  /// the blank line RFC 7578 puts between a part's header fields and its payload, and the payload.
  /// Both header values arrive escaped, so nothing here can open a line of its own.
  private mutating func write(_ data: Data, contentType: String?, disposition: String) {
    parts.append(contentsOf: "--\(boundary)\r\n".utf8)
    parts.append(contentsOf: "Content-Disposition: form-data; \(disposition)\r\n".utf8)
    if let contentType {
      parts.append(contentsOf: "Content-Type: \(contentType)\r\n".utf8)
    }
    parts.append(contentsOf: "\r\n".utf8)
    parts.append(data)
    parts.append(contentsOf: "\r\n".utf8)
  }
}

/// `raw` as a value written into a part's header block.
///
/// A carriage return or a line feed would end a header line early, so both are percent-encoded.
/// With `quotes`, a quotation mark is escaped too, which is what a value written inside a quoted
/// string needs; a media type is written without one, since a quoted parameter of its own is legal
/// there. Every other byte is written as it stands, so a name outside ASCII reaches the server as
/// the UTF-8 RFC 7578 4.2 has a recipient read. Encoding is per byte, which is what separates a
/// carriage return from the line feed following it.
private func escaped(_ raw: String, quotes: Bool = false) -> String {
  var escaped: [UInt8] = []
  escaped.reserveCapacity(raw.utf8.count)
  for byte in raw.utf8 {
    switch byte {
    case UInt8(ascii: "\"") where quotes: escaped.append(contentsOf: "%22".utf8)
    case UInt8(ascii: "\r"): escaped.append(contentsOf: "%0D".utf8)
    case UInt8(ascii: "\n"): escaped.append(contentsOf: "%0A".utf8)
    default: escaped.append(byte)
    }
  }
  return String(decoding: escaped, as: UTF8.self)
}

/// The characters a generated boundary is drawn from: the ASCII letters and digits, each of them a
/// boundary character RFC 2046 allows unquoted.
private let boundaryAlphabet = Array(
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)

/// How many characters a generated boundary carries. Thirty-two of a 62 character alphabet is about
/// 190 bits, so a boundary appearing in the bytes of a part is not a case worth encoding around.
private let boundaryLength = 32
