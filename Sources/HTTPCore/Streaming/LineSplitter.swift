// `Data` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A sequence of lines over a sequence of chunks, failing only with ``TransportError``.
///
/// The splitter splits on `\n` and on `\r\n` and gives back each line's own bytes with the
/// terminator removed. No `String` is allocated at any point: a full line's bytes are passed to
/// ``Line`` as they were gathered.
///
/// ```swift
/// let body = try await client.stream(Request(path: "/log"))
///
/// for try await line in LineSplitter(body, maxLineLength: 1 << 20) {
///   handle(String(decoding: line.bytes, as: UTF8.self))
/// }
/// ```
///
/// The base is any sequence of `Data` chunks that already speaks ``TransportError``, which is what
/// a ``StreamedBody`` is. A failure travels through untouched, read once at the boundary that made
/// it.
///
/// ## What Counts as a Line
///
/// - `\n` ends a line, and a `\r` immediately before it belongs to the terminator, not to the line.
/// - A `\r` anywhere else is data: `a\rb` is one line, and a stream whose last byte is `\r` ends
///   with that `\r` inside its final line.
/// - An empty line is a line. A blank line separates one event from the next in
///   `text/event-stream`, so dropping it would throw the framing away.
/// - Bytes left over when the base ends cleanly are emitted as a final line. A server that ends
///   without a trailing terminator is ordinary, and you can still discard a truncated tail; you
///   could not recover one this type had swallowed.
///
/// Where a chunk boundary falls makes no difference to the lines: a line split across two chunks
/// is yielded once, whole, and a chunk holding several lines yields each in order.
///
/// ## Memory
///
/// Each chunk is scanned in place through its `span`, and only the bytes of a line the chunk did
/// not finish are carried over to the next one. A base that never sends a terminator would grow
/// that carry-over without limit. `maxLineLength` bounds it: the first byte past the limit fails
/// the sequence with ``TransportError/transport(kind:underlying:)`` of kind
/// ``TransportFailureKind/other`` carrying ``LineSplitterFailure/lineTooLong(limit:)``, without
/// waiting for a terminator that may never arrive. The limit counts a line's own bytes, so neither
/// terminator counts and a line of exactly that many still arrives however it ends. The default,
/// `nil`, is unbounded.
///
/// ## Cancellation and Finishing
///
/// Cancellation belongs to the base. This type reads no cancellation state of its own, so a
/// cancelled consumer sees whatever the base reports, which is ``TransportError/cancelled`` from a
/// ``StreamedBody``. Once the base has ended or failed, the iterator releases it and every later
/// read returns `nil`; a failure is reported once and not repeated, and the bytes gathered when it
/// arrived are dropped, since nothing terminated them.
public struct LineSplitter<Base: AsyncSequence>: AsyncSequence
where Base.Element == Data, Base.Failure == TransportError {
  /// One line of the stream.
  public typealias Element = Line
  /// The only error a read can throw, which is the base's own failure type.
  public typealias Failure = TransportError

  private let base: Base
  private let maxLineLength: Int?

  /// Splits a sequence of chunks into lines.
  ///
  /// - Parameters:
  ///   - base: The sequence to read chunks from.
  ///   - maxLineLength: The most bytes a single line may carry, or `nil` for no limit.
  public init(_ base: Base, maxLineLength: Int? = nil) {
    self.base = base
    self.maxLineLength = maxLineLength
  }

  /// An iterator that scans the base's chunks and emits each completed line.
  public func makeAsyncIterator() -> Iterator {
    Iterator(base: base.makeAsyncIterator(), maxLineLength: maxLineLength)
  }

  /// The iterator over a ``LineSplitter``.
  ///
  /// It is not `Sendable`: it holds the base's iterator, which is in exclusive use by whichever
  /// task is reading it, the chunk being scanned, and the bytes of a line that chunk did not
  /// finish.
  public struct Iterator: AsyncIteratorProtocol {
    /// One line of the stream.
    public typealias Element = Line
    /// The only error `next()` can throw.
    public typealias Failure = TransportError

    /// The base's iterator, or `nil` once this iterator has finished.
    private var base: Base.AsyncIterator?
    /// The chunk being scanned, or `nil` when every byte of the last one has been read.
    private var chunk: Data?
    private let maxLineLength: Int?
    /// The bytes of the line being read that earlier chunks delivered, terminator excluded.
    private var pending: [UInt8] = []
    /// The offset into ``chunk`` of the first byte not yet scanned.
    private var position = 0

    init(base: Base.AsyncIterator, maxLineLength: Int?) {
      self.base = base
      self.maxLineLength = maxLineLength
    }

    /// The next line, or `nil` when the base has ended and nothing is left gathered.
    ///
    /// - Throws: The base's failure unchanged, or a transport failure of kind
    ///   ``TransportFailureKind/other`` carrying ``LineSplitterFailure/lineTooLong(limit:)`` when a
    ///   line outgrew the splitter's limit.
    public mutating func next(
      isolation actor: isolated (any Actor)? = #isolation
    ) async throws(TransportError) -> Line? {
      // The base is taken out for the duration of the call and put back only when a terminated line
      // came out of it, so every other outcome leaves the iterator finished with nothing to
      // release.
      guard var iterator = base.take() else { return nil }

      while true {
        do throws(TransportError) {
          if let line = try scanChunk() {
            base = iterator
            return line
          }
        } catch {
          pending = []
          throw error
        }

        let next: Data?
        do throws(TransportError) {
          next = try await iterator.next(isolation: actor)
        } catch {
          // Nothing terminated the gathered bytes, so they are not a line. They are released here
          // and not at deinit, because a consumer's `for await` holds the finished iterator alive.
          pending = []
          throw error
        }

        guard let next else {
          guard !pending.isEmpty else { return nil }
          return takePending()
        }
        chunk = next
        position = 0
      }
    }

    /// The next line the current chunk completes, or `nil` when the chunk holds no terminator
    /// after ``position``.
    ///
    /// The scan walks the chunk's `span` and moves bytes only when a line is emitted or the chunk
    /// runs out. The limit is checked byte by byte as the scan goes, so a line outgrows it at the
    /// first byte past it, and a chunk boundary inside the line changes nothing: the bytes carried
    /// over from earlier chunks count with the ones scanned here.
    ///
    /// - Throws: A transport failure carrying ``LineSplitterFailure/lineTooLong(limit:)``.
    private mutating func scanChunk() throws(TransportError) -> Line? {
      guard let chunk else { return nil }

      // The span borrows the local copy, so nothing on `self` is held while the scan runs.
      let bytes = chunk.span
      var index = position
      while index < bytes.count {
        let byte = bytes[index]
        if byte == lineFeed {
          return takeLine(endingAt: index, of: chunk)
        }
        // A carriage return at the end of what has arrived may yet turn out to be half of a
        // terminator, so it does not count against the line's length until the byte after it
        // proves it data.
        if let maxLineLength {
          let length = pending.count + index - position + (byte == carriageReturn ? 0 : 1)
          if length > maxLineLength {
            throw .transport(
              kind: .other,
              underlying: LineSplitterFailure.lineTooLong(limit: maxLineLength)
            )
          }
        }
        index += 1
      }

      // No terminator in the rest of the chunk: the line continues in the next one.
      pending.append(contentsOf: chunk[(chunk.startIndex + position)...])
      self.chunk = nil
      return nil
    }

    /// The line that the line feed at `terminator` in `chunk` completes, and moves the scan past
    /// it.
    ///
    /// - Parameters:
    ///   - terminator: The offset of the line feed in the chunk.
    ///   - chunk: The chunk being scanned.
    private mutating func takeLine(endingAt terminator: Int, of chunk: Data) -> Line {
      var bytes = pending
      pending = []
      bytes.append(
        contentsOf: chunk[(chunk.startIndex + position)..<(chunk.startIndex + terminator)])
      // A carriage return is part of the terminator only here, immediately before the line feed.
      if bytes.last == carriageReturn { bytes.removeLast() }
      position = terminator + 1
      return Line(bytes: bytes)
    }

    /// The gathered bytes as a line, leaving nothing pending.
    ///
    /// Passing the array over whole and starting a new one moves the storage to the line instead of
    /// copying it out.
    private mutating func takePending() -> Line {
      let line = Line(bytes: pending)
      pending = []
      return line
    }
  }
}

extension LineSplitter: Sendable where Base: Sendable {}

/// The byte that, immediately before a line feed, belongs to the terminator and not the line.
private let carriageReturn: UInt8 = 0x0D
/// The byte a line ends on.
private let lineFeed: UInt8 = 0x0A
