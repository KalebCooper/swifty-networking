#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPCore
import HTTPTesting
import Testing

/// The bytes of `text`.
private func utf8(_ text: String) -> [UInt8] { Array(text.utf8) }

/// A line's bytes read back as text.
private func read(_ line: Line) -> String { String(decoding: line.bytes, as: UTF8.self) }

/// A body that delivers `chunks` one element each and then ends.
private func body(_ chunks: [Data]) -> StreamedBody {
  StreamedBody(
    AsyncStream { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish()
    })
}

/// A body that delivers each of `texts` as one chunk and then ends.
private func body(_ texts: String...) -> StreamedBody {
  body(texts.map { Data($0.utf8) })
}

/// A body that delivers every byte of `bytes` as a chunk of its own, so every boundary in a
/// fixture, terminators included, falls between two arrivals.
private func byteChunks(_ bytes: [UInt8]) -> StreamedBody {
  body(bytes.map { Data([$0]) })
}

/// A body that delivers each of `texts` as one chunk and then fails.
private func failingBody(_ texts: String..., then failure: TransportError) -> StreamedBody {
  StreamedBody(
    AsyncThrowingStream<Data, any Error> { continuation in
      for text in texts { continuation.yield(Data(text.utf8)) }
      continuation.finish(throwing: failure)
    })
}

/// Reads every line, returning them with the typed failure that ended the sequence, if one did.
private func drain<Base>(_ splitter: LineSplitter<Base>) async -> (
  lines: [Line], failure: TransportError?
) {
  var lines: [Line] = []
  var iterator = splitter.makeAsyncIterator()
  do {
    while let line = try await iterator.next() {
      lines.append(line)
    }
    return (lines, nil)
  } catch {
    return (lines, error)
  }
}

/// The lines `text` splits into, read as text, whether it arrives as one chunk or a byte at a time.
private func lines(of text: String) async -> (whole: [String], byByte: [String]) {
  let whole = await drain(LineSplitter(body(text))).lines.map(read)
  let byByte = await drain(LineSplitter(byteChunks(utf8(text)))).lines.map(read)
  return (whole, byByte)
}

/// Whether the failure is ``TransportError/cancelled``.
private func isCancelled(_ error: TransportError?) -> Bool {
  if case .some(.cancelled) = error { true } else { false }
}

/// The kind of a transport failure.
private func kind(_ error: TransportError?) -> TransportFailureKind? {
  if case .some(.transport(let kind, underlying: _)) = error { kind } else { nil }
}

/// Erases a splitter the way a public API would return it.
private func erased(_ base: AsyncStream<Data>) -> some AsyncSequence<Line, TransportError> {
  LineSplitter(StreamedBody(base))
}

@Suite("LineSplitter", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct LineSplitterTests {
  @Test(
    "a stream splits on a line feed or a carriage return and line feed, terminator removed",
    arguments: [
      ("a\nb\nc\n", ["a", "b", "c"]),
      ("a\r\nb\r\nc\r\n", ["a", "b", "c"]),
      ("a\nb\r\nc\n", ["a", "b", "c"]),
      ("\n", [""]),
      ("\r\n", [""]),
      ("a\n\nb\n", ["a", "", "b"]),
      ("\n\n", ["", ""]),
      ("a\nb", ["a", "b"]),
      ("a", ["a"]),
      ("a\rb\n", ["a\rb"]),
      ("a\r", ["a\r"]),
      ("a\r\r\n", ["a\r"]),
      ("", []),
    ]
  )
  func golden(input: String, expected: [String]) async {
    let (whole, byByte) = await lines(of: input)

    #expect(whole == expected)
    #expect(byByte == expected)
  }

  @Test("a line split across two chunks is yielded once, whole")
  func lineSplitAcrossChunks() async {
    let (result, failure) = await drain(LineSplitter(body("hel", "lo\n")))

    #expect(failure == nil)
    #expect(result.map(read) == ["hello"])
  }

  @Test("a chunk holding three lines yields three lines in order")
  func chunkHoldingThreeLines() async {
    let (result, failure) = await drain(LineSplitter(body("one\ntwo\r\nthree\n")))

    #expect(failure == nil)
    #expect(result.map(read) == ["one", "two", "three"])
  }

  @Test("a trailing partial line without a newline is yielded at the end")
  func trailingPartialLine() async {
    let (result, failure) = await drain(LineSplitter(body("one\n", "tw", "o")))

    #expect(failure == nil)
    #expect(result.map(read) == ["one", "two"])
  }

  @Test("a carriage return ending one chunk and a line feed opening the next are one terminator")
  func terminatorSplitAcrossChunks() async {
    let (result, failure) = await drain(LineSplitter(body("a\r", "\nb\r", "\n")))

    #expect(failure == nil)
    #expect(result.map(read) == ["a", "b"])
  }

  @Test("an empty chunk delivers nothing and breaks no line")
  func emptyChunk() async {
    let (result, failure) = await drain(LineSplitter(body("a", "", "b\n", "")))

    #expect(failure == nil)
    #expect(result.map(read) == ["ab"])
  }

  @Test("a multibyte scalar next to a terminator stays whole inside its line")
  func multibyteBoundary() async throws {
    let (result, failure) = await drain(LineSplitter(byteChunks(utf8("é\n😀\r\ne\u{0301}\n"))))

    #expect(failure == nil)
    #expect(result.map(\.bytes) == [utf8("é"), utf8("😀"), utf8("e\u{0301}")])
    for line in result {
      let text = try UTF8Span(validating: line.bytes.span)
      #expect(text.count == line.bytes.count)
    }
  }

  @Test("a line's bytes are its own, whatever they encode")
  func bytesAreNotValidated() async {
    let (result, failure) = await drain(LineSplitter(body([Data([0xFF, 0xFE, 0x0A])])))

    #expect(failure == nil)
    #expect(result == [Line(bytes: [0xFF, 0xFE])])
  }

  @Test("a chunk that is a slice of a larger buffer is read from its own start")
  func slicedChunk() async {
    // A `Data` slice keeps its parent's indices, so a splitter reading offsets from zero would
    // read the wrong bytes.
    let parent = Data("xxa\nb".utf8)
    let slice = parent[2...]
    let (result, failure) = await drain(LineSplitter(body([slice])))

    #expect(failure == nil)
    #expect(result.map(read) == ["a", "b"])
  }

  @Test("a finished iterator keeps answering nil after the final unterminated line")
  func finishedStaysFinished() async throws {
    var iterator = LineSplitter(body("a")).makeAsyncIterator()

    #expect(try await iterator.next() == Line(bytes: utf8("a")))
    #expect(try await iterator.next() == nil)
    #expect(try await iterator.next() == nil)
  }

  @Test("a failure travels through unchanged, and the iterator is finished after it")
  func failurePropagates() async throws {
    let timedOut = TransportError.transport(kind: .timedOut, underlying: nil)
    var iterator = LineSplitter(failingBody("a\n", then: timedOut)).makeAsyncIterator()

    #expect(try await iterator.next() == Line(bytes: utf8("a")))
    #expect(await failure { try await iterator.next() }?.isTimeout == true)
    #expect(try await iterator.next() == nil)
  }

  @Test("bytes gathered when a failure arrives are dropped rather than emitted as a line")
  func partialDroppedOnFailure() async {
    let (result, failure) = await drain(
      LineSplitter(failingBody("a\npar", "tial", then: .cancelled)))

    #expect(result == [Line(bytes: utf8("a"))])
    #expect(isCancelled(failure))
  }

  @Test("a consumer cancelled while parked gets the base's cancellation, not a clean end")
  func cancelledWhileParked() async {
    // The base holds a chunk with no terminator in it, so the consumer is parked mid-line when the
    // cancellation arrives.
    let (base, continuation) = AsyncStream.makeStream(of: Data.self)
    continuation.yield(Data("a".utf8))

    let consumer = Task.immediate { await drain(LineSplitter(StreamedBody(base))) }
    consumer.cancel()
    let (result, failure) = await consumer.value

    #expect(result.isEmpty)
    #expect(isCancelled(failure))
  }

  @Test("a line of exactly the limit arrives, however it is terminated")
  func lineLengthAtTheLimit() async {
    let feed = await drain(LineSplitter(body("abc\n"), maxLineLength: 3))
    let carriageReturnFeed = await drain(LineSplitter(body("abc\r\n"), maxLineLength: 3))
    let splitFeed = await drain(LineSplitter(body("ab", "c\r", "\n"), maxLineLength: 3))

    #expect(feed.lines.map(read) == ["abc"])
    #expect(feed.failure == nil)
    #expect(carriageReturnFeed.lines.map(read) == ["abc"])
    #expect(carriageReturnFeed.failure == nil)
    #expect(splitFeed.lines.map(read) == ["abc"])
    #expect(splitFeed.failure == nil)
  }

  @Test("the first byte past the limit fails the sequence without waiting for a terminator")
  func lineLengthPastTheLimit() async {
    let (result, failure) = await drain(LineSplitter(body("abcd"), maxLineLength: 3))

    #expect(result.isEmpty)
    #expect(kind(failure) == .other)
    #expect(failure?.underlying as? LineSplitterFailure == .lineTooLong(limit: 3))
  }

  @Test("a line that outgrows the limit only in its second chunk fails the same way")
  func lineLengthPastTheLimitAcrossChunks() async {
    let (result, failure) = await drain(LineSplitter(body("ab", "cd"), maxLineLength: 3))

    #expect(result.isEmpty)
    #expect(kind(failure) == .other)
    #expect(failure?.underlying as? LineSplitterFailure == .lineTooLong(limit: 3))
  }

  @Test("a carriage return carried over from one chunk counts once the next proves it data")
  func carriedCarriageReturnCounts() async {
    let (result, failure) = await drain(LineSplitter(body("ab\r", "c\n"), maxLineLength: 3))

    #expect(result.isEmpty)
    #expect(failure?.underlying as? LineSplitterFailure == .lineTooLong(limit: 3))
  }

  @Test("a LineSplitter erases to some AsyncSequence<Line, TransportError>")
  func erasure() async throws {
    let (base, continuation) = AsyncStream.makeStream(of: Data.self)
    continuation.yield(Data("a\nb\n".utf8))
    continuation.finish()

    var result: [String] = []
    // Iterated by hand rather than with `for try await`: an assertions build of the compiler asserts
    // on that loop over an erased typed-throws sequence.
    var iterator = erased(base).makeAsyncIterator()
    while let line = try await iterator.next() {
      result.append(read(line))
    }

    #expect(result == ["a", "b"])
  }

  @Test("a LineSplitter over a Sendable base is Sendable")
  func sendability() {
    let splitter: any Sendable = LineSplitter(body())

    #expect(splitter is LineSplitter<StreamedBody>)
  }
}
