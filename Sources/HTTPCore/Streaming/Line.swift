/// One line of a byte stream, with its terminator removed.
///
/// The bytes are the line's own, exactly as they arrived: nothing is validated, nothing is decoded,
/// and no `String` is allocated. A line that is not valid UTF-8 is still a line, and what to do
/// about that belongs to whoever asked for the split.
///
/// ## Reading the Bytes
///
/// Take the borrowed view in the scope that consumes it:
///
/// ```swift
/// for try await line in LineSplitter(bytes) {
///   let text = try UTF8Span(validating: line.bytes.span)
///   handle(String(copying: text))
/// }
/// ```
///
/// Neither `span` nor `utf8Span` is a member of this type: a member handing back a borrow of its
/// own storage needs a lifetime annotation this package does not spell, so the borrow is taken
/// where it is read and escapes nothing. `String(decoding: line.bytes, as: UTF8.self)` is the lossy
/// but total reading, and `Data(line.bytes)` is one copy into a decoder.
public struct Line: Equatable, Hashable, Sendable {
  /// The line's own bytes, without the `\n` or `\r\n` that ended it.
  public let bytes: [UInt8]

  /// Creates a line from bytes whose terminator has already been removed.
  ///
  /// - Parameter bytes: The line's own bytes.
  public init(bytes: [UInt8]) {
    self.bytes = bytes
  }
}
