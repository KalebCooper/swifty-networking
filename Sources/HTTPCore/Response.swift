// `Data` and the JSON decoder are the only Foundation types this file needs. The iOS SDK ships no
// separate FoundationEssentials module, so full Foundation is imported where that is the only
// option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTypes

/// A complete response: status, header fields, and the fully buffered body.
///
/// A response is a plain value a transport or a test builds with no coder in scope;
/// ``decode(_:with:)`` takes one when you want it.
///
/// ```swift
/// let response: Response = try await client.execute(Request(path: "/report.csv"))
/// print(response.status.code, response.headers[.contentType] ?? "", response.body.count)
/// ```
public struct Response: Hashable, Sendable {
  /// The full response body; empty when the server sent none.
  public var body: Data

  /// The response header fields.
  public var headers: HTTPFields

  /// The response status.
  public var status: HTTPResponse.Status

  /// Creates a response.
  ///
  /// - Parameters:
  ///   - body: The response body; defaults to empty.
  ///   - headers: The response header fields; defaults to none.
  ///   - status: The response status.
  public init(body: Data = Data(), headers: HTTPFields = [:], status: HTTPResponse.Status) {
    self.body = body
    self.headers = headers
    self.status = status
  }
}

extension Response {
  /// The body size at which decoding moves off the caller's executor, in bytes.
  ///
  /// Decoding JSON is the only unbounded CPU work a response costs, and the cost grows with the
  /// payload. Held on the caller's actor, a large parse is dropped frames. Below the threshold the
  /// hop to another executor and back costs more than the parse it would move.
  private static let concurrentDecodeThreshold = 16 * 1024

  /// The bytes `<!doctype html`, held lowercase so a case-folded comparison reaches them.
  private static let doctypeSignature = Array("<!doctype html".utf8)

  /// The gzip member header.
  private static let gzipSignature: [UInt8] = [0x1F, 0x8B]

  /// The bytes `<html`, held lowercase so a case-folded comparison reaches them.
  private static let htmlSignature = Array("<html".utf8)

  /// The JPEG start-of-image marker.
  private static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]

  /// The PDF header, `%PDF-`.
  ///
  /// These are the literal bytes, so they are compared for equality rather than through the
  /// case-folding `matches(_:at:)`: a body opening `%pdf-` is not a PDF.
  private static let pdfSignature = Array("%PDF-".utf8)

  /// The eight-byte PNG signature.
  private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

  /// The bytes `<?xml`, held lowercase so a case-folded comparison reaches them.
  private static let xmlSignature = Array("<?xml".utf8)

  /// Returns what the body's own leading bytes identify it as.
  ///
  /// Only the leading bytes are read, and only as far as the first answer: a binary signature is
  /// compared against the body directly, and the text signatures are walked over a borrowed
  /// `body.span`. Neither copies the body, so the cost is the length of a signature however large
  /// the response is. The `Content-Type` field is not consulted: it is the server's claim, and the
  /// cases where you need this method are the cases where the claim was wrong, such as a proxy's
  /// HTML error page served as `application/json`. Read ``headers`` for the claim.
  ///
  /// Which bytes name each case, and whether leading whitespace is skipped before they are read, is
  /// documented on ``ContentTypeSniff``.
  ///
  /// ```swift
  /// guard response.contentTypeSniff() == .json else { throw PayloadError.notJSON }
  /// ```
  ///
  /// - Returns: What the leading bytes identify the body as.
  public func contentTypeSniff() -> ContentTypeSniff {
    // A binary signature identifies a body from its very first byte: whitespace in front of one
    // means the bytes are not that format, so these are read before anything is skipped.
    if body.starts(with: Self.gzipSignature) { return .gzip }
    if body.starts(with: Self.jpegSignature) { return .jpeg }
    if body.starts(with: Self.pdfSignature) { return .pdf }
    if body.starts(with: Self.pngSignature) { return .png }

    let bytes = body.span
    var index = 0
    while index < bytes.count {
      switch bytes[index] {
      // The four characters JSON allows between tokens, so a pretty-printed or newline-prefixed
      // payload is still recognised. The text signatures below are read after them for the same
      // reason: a served document routinely begins with a newline.
      case 0x09, 0x0A, 0x0D, 0x20:
        index += 1
      // `[` and `{`.
      case 0x5B, 0x7B:
        return .json
      // `<`, which begins every markup signature. The second byte is what separates them, `?` for
      // the XML declaration, `!` for the doctype, and `h` for the tag, so no two can match the same
      // body and the order they are tried in carries no meaning.
      case 0x3C:
        if matches(Self.xmlSignature, at: index) { return .xml }
        if matches(Self.doctypeSignature, at: index) { return .html }
        if matches(Self.htmlSignature, at: index) { return .html }
        return .unknown
      default:
        return .unknown
      }
    }
    return .empty
  }

  /// Decodes the body as `Value`, where the caller already is or off it, whichever the body's size
  /// makes cheaper.
  ///
  /// This is the decode ``HTTPClient``'s typed `execute(_:)` performs, available on a response you
  /// took from ``HTTPClient/execute(_:)->Response`` or built yourself, so reading a raw response
  /// costs neither a hand-written decode nor a large body parsed where the caller is running. The
  /// decoded value crosses back as `sending` either way, so which executor ran the parse is
  /// invisible to the caller and `Value` need not be `Sendable`. `Value` must have a `Sendable`
  /// metatype, which every concrete type has unless its `Decodable` conformance is isolated to a
  /// global actor.
  ///
  /// A body at or below 16 KiB is decoded where the caller runs, and a larger one on the concurrent
  /// executor. The decoder may be read on that executor, so do not mutate it while a decode is in
  /// flight.
  ///
  /// The status is not consulted: an error body decodes exactly as a successful one does. Read
  /// ``status`` first when it matters.
  ///
  /// ```swift
  /// let response = try await client.execute(Request(path: "/me")) as Response
  /// let profile = try await response.decode(Profile.self, with: JSONDecoder())
  /// ```
  ///
  /// - Parameters:
  ///   - type: The type to decode; inferred from the context when you leave it out.
  ///   - decoder: The decoder to read the body with.
  /// - Returns: The decoded body.
  /// - Throws: ``TransportError/decode(underlying:)`` when the body is not a `Value`.
  public func decode<Value: Decodable & SendableMetatype>(
    _ type: Value.Type = Value.self,
    with decoder: JSONDecoder
  ) async throws(TransportError) -> sending Value {
    if body.count > Self.concurrentDecodeThreshold {
      return try await decodeConcurrently(type, with: decoder)
    }
    return try decodeInline(type, with: decoder)
  }

  /// The same decode, moved off the caller's executor because the body is large enough that parsing
  /// it would be felt where the caller is running.
  @concurrent
  private func decodeConcurrently<Value: Decodable & SendableMetatype>(
    _ type: Value.Type,
    with decoder: JSONDecoder
  ) async throws(TransportError) -> sending Value {
    try decodeInline(type, with: decoder)
  }

  // The result is returned plain, not `sending`: every input is `Sendable`, so the callers prove the
  // value disconnected on their own, and an assertions build of the compiler asserts when a `sending`
  // result and a typed rethrow share one body.
  /// The decode itself, run wherever it is called from.
  private func decodeInline<Value: Decodable & SendableMetatype>(
    _ type: Value.Type,
    with decoder: JSONDecoder
  ) throws(TransportError) -> Value {
    do {
      return try decoder.decode(type, from: body)
    } catch {
      throw .decode(underlying: error)
    }
  }

  /// Returns a Boolean value that indicates whether the body's bytes from `index` equal `signature`,
  /// with an ASCII letter in the body matching either case.
  ///
  /// - Parameters:
  ///   - signature: The bytes to look for, lowercase wherever they are ASCII letters.
  ///   - index: Where in the body to start comparing.
  /// - Returns: `true` when the body from `index` begins with `signature`.
  private func matches(_ signature: some Collection<UInt8>, at index: Int) -> Bool {
    let bytes = body.span
    guard signature.count <= bytes.count - index else { return false }
    var offset = index
    for byte in signature {
      // `A` through `Z` fold to lowercase by one addition; every other byte compares as it stands.
      let candidate = bytes[offset]
      let folded = (0x41...0x5A).contains(candidate) ? candidate + 0x20 : candidate
      if folded != byte { return false }
      offset += 1
    }
    return true
  }
}
