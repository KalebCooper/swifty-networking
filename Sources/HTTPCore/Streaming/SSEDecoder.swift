// `Data` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A sequence of server-sent events over a sequence of chunks, failing only with
/// ``TransportError``.
///
/// `text/event-stream` is a line format framed by blank lines: fields accumulate, and a blank line
/// dispatches what they add up to. This type splits the chunks into lines through a
/// ``LineSplitter``, reads each one as the WHATWG event-stream grammar defines it, and yields an
/// event every time a frame closes.
///
/// ```swift
/// let body = try await client.stream(Request(path: "/events"))
///
/// for try await event in SSEDecoder(body) {
///   handle(event)
/// }
/// ```
///
/// The base is any sequence of `Data` chunks that already speaks ``TransportError``, which is what
/// a ``StreamedBody`` is. Where a chunk boundary falls makes no difference: a field split across
/// two chunks decodes intact. A failure travels through untouched, read once at the boundary that
/// made it.
///
/// ## What Each Line Means
///
/// - A blank line closes the frame. If any `data` field arrived in it, an event is dispatched; if
///   none did, nothing is, which is how a server sends an id or a reconnection time on its own.
/// - A line beginning with `:` is a comment and is ignored. Servers send bare colons as
///   keep-alives.
/// - Otherwise the first `:` separates a field name from its value, and one space immediately after
///   the colon belongs to the framing, not to the value. A line with no colon at all is a field of
///   that name with an empty value.
/// - `data` appends a line to the event's data, `event` names its type, `id` sets the stream's last
///   event id unless the value contains a null, and `retry` sets the stream's reconnection time
///   when the value is a whole number of milliseconds this reader can represent. Every other field
///   name is ignored.
/// - A frame left open when the stream ends is discarded, because nothing said it was complete.
///
/// ## Text
///
/// An event stream is UTF-8 by specification, so every line is validated as UTF-8, comments and
/// unknown fields included. A line that is not valid UTF-8 ends the sequence with
/// ``TransportError/decode(underlying:)`` carrying the standard library's own
/// `UTF8.ValidationError`, which names the byte that broke it. Events already delivered stand.
///
/// This is stricter than the grammar, which substitutes a replacement character. A replacement
/// character cannot be told from one the server meant to send, so it would give you corrupted text
/// with nothing to act on, where a typed failure says what went wrong.
///
/// Validation allocates nothing, and a `String` is built only for a field value that is kept, so a
/// comment, an unknown field, and a `retry` value cost none.
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
public struct SSEDecoder<Base: AsyncSequence>: AsyncSequence
where Base.Element == Data, Base.Failure == TransportError {
  /// One dispatched event.
  public typealias Element = ServerSentEvent
  /// The only error a read can throw, which is the base's own failure type.
  public typealias Failure = TransportError

  private let lines: LineSplitter<Base>

  /// Reads a sequence of chunks as an event stream.
  ///
  /// - Parameters:
  ///   - base: The sequence to read chunks from.
  ///   - maxLineLength: The most bytes a single line may carry, or `nil` for no limit.
  public init(_ base: Base, maxLineLength: Int? = nil) {
    lines = LineSplitter(base, maxLineLength: maxLineLength)
  }

  /// An iterator that gathers the base's lines into frames and emits each dispatched event.
  public func makeAsyncIterator() -> Iterator {
    Iterator(base: lines.makeAsyncIterator())
  }

  /// The iterator over an ``SSEDecoder``.
  ///
  /// It is not `Sendable`: it holds the line splitter's iterator over the base, which is in
  /// exclusive use by whichever task is reading it, along with the frame being gathered and the
  /// stream state that outlives it.
  public struct Iterator: AsyncIteratorProtocol {
    /// One dispatched event.
    public typealias Element = ServerSentEvent
    /// The only error `next()` can throw.
    public typealias Failure = TransportError

    /// The line splitter's iterator over the base, or `nil` once this iterator has finished.
    private var base: LineSplitter<Base>.Iterator?
    /// The current frame's `data` fields, in arrival order.
    ///
    /// The values are kept separately and joined at dispatch. Appending them to one buffer with a
    /// line feed after each would mean removing the buffer's last `Character` at dispatch, and for
    /// a data value ending in a carriage return that character is `\r\n`, which would take the
    /// carriage return with it.
    private var data: [String] = []
    /// The current frame's `event` field, or the empty string when it named none.
    private var eventType = ""
    /// The stream's last event id as the grammar keeps it, which outlives the frame that set it.
    ///
    /// `nil` until the stream sets one, and the empty string once it has cleared one, so a reader
    /// that carries an id across connections can tell a stream that said nothing from one that
    /// asked for the id to be dropped. ``EventSource`` reads it when a connection ends, which is how
    /// an id set by a frame that dispatched no event still reaches the reconnect, and sets it when
    /// the next connection opens, so an event on that connection reports the id the stream last
    /// sent rather than none until the server sends one again.
    var lastEventID: String?
    /// The stream's reconnection time, which outlives the frame that set it, or `nil` until the
    /// stream sends one. Read through ``EventSource`` the way ``lastEventID`` is.
    private(set) var reconnectionTime: Duration?

    init(base: LineSplitter<Base>.Iterator) {
      self.base = base
    }

    /// The next event, or `nil` when the base has ended with no further frame closed in it.
    ///
    /// - Throws: The base's failure unchanged, the line splitter's own failure for a line past
    ///   `maxLineLength`, or ``TransportError/decode(underlying:)`` carrying a
    ///   `UTF8.ValidationError` when a line is not valid UTF-8.
    public mutating func next(
      isolation actor: isolated (any Actor)? = #isolation
    ) async throws(TransportError) -> ServerSentEvent? {
      // The base is taken out for the duration of the call and put back only when an event came out
      // of it, so every other outcome leaves the iterator finished with nothing to release.
      guard var iterator = base.take() else { return nil }

      while true {
        let line: Line?
        do throws(TransportError) {
          line = try await iterator.next(isolation: actor)
        } catch {
          discardFrame()
          throw error
        }

        guard let line else {
          // No blank line ever closed the frame being gathered, so there is no event in it.
          discardFrame()
          return nil
        }

        guard !line.bytes.isEmpty else {
          guard let event = dispatch() else { continue }
          base = iterator
          return event
        }

        do throws(TransportError) {
          try consume(line)
        } catch {
          discardFrame()
          throw error
        }
      }
    }

    /// The event the frame that just closed carries, or `nil` when it carries none.
    private mutating func dispatch() -> ServerSentEvent? {
      // Only the frame's own fields reset: the last event id and the reconnection time belong to
      // the stream, and are reported on every event until the stream itself replaces them.
      defer {
        data = []
        eventType = ""
      }

      // A frame with no data field at all dispatches nothing, which is how a server sends an id or
      // a reconnection time without sending an event. A frame whose data fields were all empty is
      // not that: it dispatches an event carrying the empty string.
      guard !data.isEmpty else { return nil }

      let identifier = lastEventID.flatMap { $0.isEmpty ? nil : $0 }
      let payload = data.joined(separator: "\n")

      // The type's own default supplies the grammar's `message`, so that name is spelled once.
      guard !eventType.isEmpty else {
        return ServerSentEvent(data: payload, id: identifier, retry: reconnectionTime)
      }
      return ServerSentEvent(
        data: payload, event: eventType, id: identifier, retry: reconnectionTime)
    }

    /// Drops the frame being gathered, leaving the stream state the grammar keeps across frames.
    ///
    /// It is released here and not at deinit, because a consumer's `for await` holds the finished
    /// iterator alive.
    private mutating func discardFrame() {
      data = []
      eventType = ""
    }

    /// Reads one non-empty line into the frame being gathered.
    ///
    /// - Throws: ``TransportError/decode(underlying:)`` carrying a `UTF8.ValidationError` when the
    ///   line is not valid UTF-8.
    private mutating func consume(_ line: Line) throws(TransportError) {
      do {
        // The specification requires the whole stream to be UTF-8, so a line that is not one is a
        // broken stream and not a line to skip past, comments included. The borrowed view is
        // consumed here and escapes nothing, and validating allocates no storage of its own.
        _ = try UTF8Span(validating: line.bytes.span)
      } catch {
        throw .decode(underlying: error)
      }

      let bytes = line.bytes
      // A leading colon marks a comment, which is what a server sends to hold a connection open.
      guard bytes.first != colon else { return }

      let name: ArraySlice<UInt8>
      var value: ArraySlice<UInt8>
      if let separator = bytes.firstIndex(of: colon) {
        name = bytes[..<separator]
        value = bytes[bytes.index(after: separator)...]
        // One space after the colon belongs to the framing, not to the value; a second one is the
        // value's own.
        if value.first == space { value = value.dropFirst() }
      } else {
        name = bytes[...]
        value = bytes[bytes.endIndex...]
      }

      // Slicing at a colon and past a space lands on scalar boundaries either way, both being
      // ASCII, so reading a value as text is total here: the line it came out of was validated
      // whole.
      if name.elementsEqual("data".utf8) {
        data.append(String(decoding: value, as: UTF8.self))
      } else if name.elementsEqual("event".utf8) {
        eventType = String(decoding: value, as: UTF8.self)
      } else if name.elementsEqual("id".utf8) {
        // A null is the one byte an id may not carry, since the id travels back to the server in a
        // header field that cannot hold one.
        if !value.contains(null) { lastEventID = String(decoding: value, as: UTF8.self) }
      } else if name.elementsEqual("retry".utf8) {
        if let value = milliseconds(of: value) { reconnectionTime = .milliseconds(value) }
      }
      // Any other field name is ignored, as the grammar says to do with one it does not define.
    }
  }
}

extension SSEDecoder: Sendable where Base: Sendable {}

/// The byte that separates a field's name from its value, and that marks a comment when it leads.
private let colon: UInt8 = 0x3A
/// The largest byte that is an ASCII digit.
private let digitNine: UInt8 = 0x39
/// The smallest byte that is an ASCII digit, and the one every digit's value is measured from.
private let digitZero: UInt8 = 0x30
/// The byte an event id may not carry.
private let null: UInt8 = 0x00
/// The byte after a colon that belongs to the framing and not to the value.
private let space: UInt8 = 0x20

/// The value read as a whole number of milliseconds, or `nil` when it is not one.
///
/// The grammar ignores a value carrying anything but ASCII digits, and this reader also ignores an
/// empty one and one too large to represent. No `String` is built to answer this.
private func milliseconds(of bytes: ArraySlice<UInt8>) -> Int? {
  guard !bytes.isEmpty else { return nil }

  var total = 0
  for byte in bytes {
    guard byte >= digitZero, byte <= digitNine else { return nil }
    let (scaled, scaleOverflowed) = total.multipliedReportingOverflow(by: 10)
    guard !scaleOverflowed else { return nil }
    let (sum, sumOverflowed) = scaled.addingReportingOverflow(Int(byte - digitZero))
    guard !sumOverflowed else { return nil }
    total = sum
  }
  return total
}
