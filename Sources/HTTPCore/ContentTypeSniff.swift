/// What a response body's own leading bytes identify it as.
///
/// The cases answer three questions: whether there is anything to decode, which format the leading
/// bytes name, and whether the body is something else entirely.
///
/// Three rules decide the answer. A binary signature is read at the body's very first byte, so a
/// body that begins with whitespace is not gzip, JPEG, PDF, or PNG whatever follows the whitespace.
/// A text signature is read after any leading whitespace, because a text body routinely arrives
/// with a leading newline. The markup signatures, `<?xml`, `<!doctype html`, and `<html`, are
/// compared without regard to case, because a served document spells them either way. A signature
/// is a prefix and nothing beyond it is examined, so this diagnoses a body rather than validating
/// one.
///
/// ```swift
/// switch response.contentTypeSniff() {
/// case .empty: return nil
/// case .json: return try decoder.decode(Payload.self, from: response.body)
/// default: throw PayloadError.notJSON
/// }
/// ```
public enum ContentTypeSniff: Hashable, Sendable {
  /// The body carries nothing to decode: no bytes at all, or only whitespace.
  ///
  /// Whitespace counts as nothing, so a lone newline after a `204` reads as empty.
  case empty

  /// The body begins with the gzip member header, `1F 8B`.
  case gzip

  /// The body begins with `<html` or `<!DOCTYPE html`, compared without regard to case.
  ///
  /// The prefix is the whole test: `<htmlish>` reads as HTML, while `<head>` and `<hr>` do not.
  case html

  /// The body begins with the JPEG start-of-image marker, `FF D8 FF`.
  case jpeg

  /// The body begins with the opening byte of a JSON object or array.
  ///
  /// Only `{` and `[` qualify. A top-level JSON string, number, or keyword is legal JSON but cannot
  /// be told from plain text by its first byte.
  case json

  /// The body begins with the PDF header, `%PDF-`.
  case pdf

  /// The body begins with the eight-byte PNG signature, `89 50 4E 47 0D 0A 1A 0A`.
  ///
  /// All eight bytes are required, so the four that spell `\u{89}PNG` on their own do not qualify.
  case png

  /// The body has content, and its leading bytes do not identify it.
  case unknown

  /// The body begins with the XML declaration, `<?xml`, compared without regard to case.
  case xml
}
