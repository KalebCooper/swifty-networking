// `Data` and the JSON decoder are the only Foundation types this file needs, and the iOS SDK ships
// no separate FoundationEssentials module, so the smaller import is taken wherever it exists and
// full Foundation only where it is the sole option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A sequence of values decoded from newline-delimited JSON, failing only with ``TransportError``.
///
/// Newline-delimited JSON is one complete JSON value per line, so a value is ready the moment its
/// line ends and you see each record as it arrives. This type splits the chunks into lines through
/// a ``LineSplitter``, gives each line's bytes to a `JSONDecoder`, and yields what comes back.
///
/// ```swift
/// struct Record: Decodable, Sendable {
///   let id: Int
/// }
///
/// let body = try await client.stream(Request(path: "/records.ndjson"))
///
/// for try await record in NDJSONDecoder(body, decoding: Record.self) {
///   handle(record)
/// }
/// ```
///
/// The base is any sequence of `Data` chunks that already speaks ``TransportError``, which is what
/// a ``StreamedBody`` is. Where a chunk boundary falls makes no difference: a value split across
/// two chunks decodes intact. A failure travels through untouched, read once at the boundary that
/// made it.
///
/// ## What Each Line Means
///
/// - A line carrying nothing a decoder could read, meaning no bytes at all or only the tab, line
///   feed, carriage return, and space that JSON counts as whitespace, is skipped. Writers emit
///   blank lines between records and at the end of a stream, and ``LineSplitter`` passes them on
///   faithfully.
/// - Every other line is offered to the decoder whole. A line the decoder rejects ends the sequence
///   with ``TransportError/decode(underlying:)`` carrying the decoder's own error, so schema drift
///   reaches you instead of being skipped silently. Values already delivered stand.
/// - The unterminated final line ``LineSplitter`` emits is an ordinary line here, so a stream cut
///   off mid-record ends in a decode failure.
///
/// ## Memory
///
/// `maxLineLength` is handed to the ``LineSplitter`` underneath and bounds what one line may
/// gather before a terminator arrives; see ``LineSplitter`` for the failure it reports. The
/// default, `nil`, is unbounded.
///
/// ## Cancellation and Finishing
///
/// Cancellation belongs to whatever produced the chunks. This type reads no cancellation state of
/// its own, so a cancelled consumer sees whatever the base reports, which is
/// ``TransportError/cancelled`` from a ``StreamedBody``. Once the base has ended or a read has
/// failed, the iterator releases it and every later read returns `nil`; a failure is reported once
/// and not repeated.
public struct NDJSONDecoder<Base: AsyncSequence, Value: Decodable & SendableMetatype>: AsyncSequence
where Base.Element == Data, Base.Failure == TransportError {
  /// One decoded value.
  public typealias Element = Value
  /// The only error a read can throw, which is the base's own failure type.
  public typealias Failure = TransportError

  private let decoder: JSONDecoder
  private let lines: LineSplitter<Base>
  private let valueType: Value.Type

  /// Decodes each line of a sequence of chunks as one JSON value.
  ///
  /// You name the value type at the call site, the way `JSONDecoder.decode(_:from:)` does, and the
  /// base is inferred from the argument. Swift has no way to spell only some of a generic type's
  /// parameters, and this type is generic over its base as well, so `NDJSONDecoder<Record>(lines)`
  /// cannot be written. The type is held for the life of the sequence, which is why it must be one
  /// with a `Sendable` metatype; every concrete type is, so you write the bound out only in generic
  /// code of your own.
  ///
  /// - Parameters:
  ///   - base: The sequence to read chunks from.
  ///   - decoder: The decoder each line's bytes are handed to; defaults to a plain `JSONDecoder()`.
  ///   - valueType: The type each line decodes as.
  ///   - maxLineLength: The most bytes a single line may carry, or `nil` for no limit.
  public init(
    _ base: Base,
    decoder: JSONDecoder = JSONDecoder(),
    decoding valueType: Value.Type,
    maxLineLength: Int? = nil
  ) {
    self.decoder = decoder
    lines = LineSplitter(base, maxLineLength: maxLineLength)
    self.valueType = valueType
  }

  /// An iterator that decodes the base's lines one value at a time.
  public func makeAsyncIterator() -> Iterator {
    Iterator(base: lines.makeAsyncIterator(), decoder: decoder, valueType: valueType)
  }

  /// The iterator over an ``NDJSONDecoder``.
  ///
  /// It is not `Sendable`: it holds the line splitter's iterator over the base, which is in
  /// exclusive use by whichever task is reading it.
  public struct Iterator: AsyncIteratorProtocol {
    /// One decoded value.
    public typealias Element = Value
    /// The only error `next()` can throw.
    public typealias Failure = TransportError

    /// The line splitter's iterator over the base, or `nil` once this iterator has finished.
    private var base: LineSplitter<Base>.Iterator?
    private let decoder: JSONDecoder
    private let valueType: Value.Type

    init(base: LineSplitter<Base>.Iterator, decoder: JSONDecoder, valueType: Value.Type) {
      self.base = base
      self.decoder = decoder
      self.valueType = valueType
    }

    /// The next value, or `nil` when the base has ended with no further record in it.
    ///
    /// - Throws: The base's failure unchanged, the line splitter's own failure for a line past
    ///   `maxLineLength`, or ``TransportError/decode(underlying:)`` carrying the decoder's error
    ///   when a line is not a value of the decoded type.
    public mutating func next(
      isolation actor: isolated (any Actor)? = #isolation
    ) async throws(TransportError) -> Value? {
      // The base is taken out for the duration of the call and put back only when a value came out
      // of it, so every other outcome leaves the iterator finished with nothing to release.
      guard var iterator = base.take() else { return nil }

      while let line = try await iterator.next(isolation: actor) {
        guard !isBlank(line) else { continue }

        let value: Value
        do {
          // The decoder takes `Data` and nothing lighter, so this copy is unavoidable. A line's
          // bytes are its own and are not needed after it.
          value = try decoder.decode(valueType, from: Data(line.bytes))
        } catch {
          throw .decode(underlying: error)
        }

        base = iterator
        return value
      }
      return nil
    }
  }
}

extension NDJSONDecoder: Sendable where Base: Sendable {}

/// Whether the line carries nothing a decoder could read.
private func isBlank(_ line: Line) -> Bool {
  line.bytes.allSatisfy { byte in
    // Tab, line feed, carriage return, and space are the whole of what JSON counts as whitespace,
    // so a line of only these carries no value to decode.
    switch byte {
    case 0x09, 0x0A, 0x0D, 0x20: true
    default: false
    }
  }
}
