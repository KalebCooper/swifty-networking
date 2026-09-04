/// A failure a ``LineSplitter`` reports about itself, as opposed to one that came up the stream.
///
/// It is public so you can tell a limit you set apart from a network failure you did not: read
/// `error.underlying as? LineSplitterFailure` to find out which, where a bare
/// ``TransportFailureKind/other`` would leave the question open.
///
/// ```swift
/// do {
///   for try await line in LineSplitter(bytes, maxLineLength: 1 << 20) { handle(line) }
/// } catch {
///   if let failure = error.underlying as? LineSplitterFailure,
///     case .lineTooLong(let limit) = failure
///   {
///     report("A line exceeded \(limit) bytes.")
///   }
/// }
/// ```
///
/// The enum carries one case today, and is an enum so a later reason can be added without changing
/// what you already match on.
public enum LineSplitterFailure: Error, Hashable, Sendable {
  /// More bytes than the splitter's limit arrived with no terminator among them.
  ///
  /// - Parameter limit: The `maxLineLength` the splitter was given.
  case lineTooLong(limit: Int)
}
