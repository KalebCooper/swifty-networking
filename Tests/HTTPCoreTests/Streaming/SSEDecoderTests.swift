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
/// fixture falls between two arrivals.
private func byteChunks(_ bytes: [UInt8]) -> StreamedBody {
  body(bytes.map { Data([$0]) })
}

/// A body that delivers `text` as one chunk and then fails instead of ending cleanly.
private func failingBody(_ text: String, then failure: TransportError) -> StreamedBody {
  StreamedBody(
    AsyncThrowingStream<Data, any Error> { continuation in
      continuation.yield(Data(text.utf8))
      continuation.finish(throwing: failure)
    })
}

/// Reads every event, returning them with the typed failure that ended the sequence, if one did.
private func drain<Base>(_ decoder: SSEDecoder<Base>) async -> (
  events: [ServerSentEvent], failure: TransportError?
) {
  var events: [ServerSentEvent] = []
  var iterator = decoder.makeAsyncIterator()
  do {
    while let event = try await iterator.next() {
      events.append(event)
    }
    return (events, nil)
  } catch {
    return (events, error)
  }
}

/// The events `text` dispatches, dropping how the sequence ended, whether it arrives as one chunk
/// or a byte at a time.
private func events(of text: String) async -> (whole: [ServerSentEvent], byByte: [ServerSentEvent])
{
  let whole = await drain(SSEDecoder(body(text))).events
  let byByte = await drain(SSEDecoder(byteChunks(utf8(text)))).events
  return (whole, byByte)
}

/// Whether the failure is ``TransportError/decode(underlying:)``.
private func isDecode(_ error: TransportError?) -> Bool {
  if case .some(.decode) = error { true } else { false }
}

/// Whether the failure is ``TransportError/cancelled``.
private func isCancelled(_ error: TransportError?) -> Bool {
  if case .some(.cancelled) = error { true } else { false }
}

/// Erases a decoder the way a public API would return it.
private func erased(_ base: AsyncStream<Data>) -> some AsyncSequence<
  ServerSentEvent, TransportError
> {
  SSEDecoder(StreamedBody(base))
}

private let a = ServerSentEvent(data: "a")
private let b = ServerSentEvent(data: "b")

@Suite("SSEDecoder", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct SSEDecoderTests {
  @Test(
    "a blank line dispatches what the fields before it add up to",
    arguments: [
      ("data: a\n\n", [a]),
      ("data: a\n\ndata: b\n\n", [a, b]),
      // The value is the rest of the line, colons in it included.
      ("data: a: b\n\n", [ServerSentEvent(data: "a: b")]),
      // Exactly one space after the colon is framing; a second one is the value's own.
      ("data:a\n\n", [a]),
      ("data:  a\n\n", [ServerSentEvent(data: " a")]),
      // Several data fields are one event's data, joined by a line feed.
      ("data: a\ndata: b\n\n", [ServerSentEvent(data: "a\nb")]),
      ("data: a\r\ndata: b\r\n\r\n", [ServerSentEvent(data: "a\nb")]),
      // A carriage return that is not part of a terminator is data, and survives the join.
      ("data: a\r\r\n\r\n", [ServerSentEvent(data: "a\r")]),
      // A line beginning with a colon is a comment, bare keep-alives included.
      (":\n: keep-alive\ndata: a\n\n", [a]),
      // A line with no colon is a field of that name carrying an empty value.
      ("data\n\n", [ServerSentEvent(data: "")]),
      ("data:\n\n", [ServerSentEvent(data: "")]),
      // A frame with no data field dispatches nothing.
      ("", []),
      ("\n\n\n", []),
      ("event: ping\n\n", []),
      (": comment\n\n", []),
      // An unknown field name is ignored.
      ("unknown: x\ndata: a\n\n", [a]),
      // The event type is the frame's own, and does not carry into the next frame.
      ("event: update\ndata: a\n\n", [ServerSentEvent(data: "a", event: "update")]),
      ("event: update\ndata: a\n\ndata: b\n\n", [ServerSentEvent(data: "a", event: "update"), b]),
      // The id belongs to the stream and carries into later frames.
      (
        "id: 1\ndata: a\n\ndata: b\n\n",
        [
          ServerSentEvent(data: "a", id: "1"), ServerSentEvent(data: "b", id: "1"),
        ]
      ),
      // An id field with an empty value clears it, which reads back as no id at all.
      ("id: 1\ndata: a\n\nid\ndata: b\n\n", [ServerSentEvent(data: "a", id: "1"), b]),
      // An id carrying a null is ignored, and leaves the one already in force.
      (
        "id: 1\ndata: a\n\nid: 2\u{0}\ndata: b\n\n",
        [
          ServerSentEvent(data: "a", id: "1"), ServerSentEvent(data: "b", id: "1"),
        ]
      ),
      // A retry that is not a whole number of milliseconds, or is too large to represent, is ignored.
      ("retry: 3000\ndata: a\n\n", [ServerSentEvent(data: "a", retry: .milliseconds(3000))]),
      ("retry: 3s\ndata: a\n\n", [a]),
      ("retry:\ndata: a\n\n", [a]),
      ("retry: 99999999999999999999\ndata: a\n\n", [a]),
      // A frame of nothing but a retry dispatches no event, and the value reaches the next one.
      ("retry: 3000\n\ndata: a\n\n", [ServerSentEvent(data: "a", retry: .milliseconds(3000))]),
      // A frame the stream ended in the middle of is discarded.
      ("data: a\n\ndata: b\n", [a]),
      ("data: a", []),
    ]
  )
  func golden(input: String, expected: [ServerSentEvent]) async {
    let (whole, byByte) = await events(of: input)

    #expect(whole == expected)
    #expect(byByte == expected)
  }

  @Test("an SSE event whose data field straddles a chunk boundary decodes intact")
  func dataFieldStraddlesAChunkBoundary() async {
    let (events, failure) = await drain(SSEDecoder(body("event: tick\nda", "ta: hel", "lo\n\n")))

    #expect(failure == nil)
    #expect(events == [ServerSentEvent(data: "hello", event: "tick")])
  }

  @Test("a blank line arriving as its own chunk still closes the frame")
  func blankLineInItsOwnChunk() async {
    let (events, failure) = await drain(SSEDecoder(body("data: a\n", "\n", "data: b\n", "\n")))

    #expect(failure == nil)
    #expect(events == [a, b])
  }

  @Test("a multibyte scalar inside a field survives the split and the read")
  func multibyteScalar() async {
    let (events, failure) = await drain(
      SSEDecoder(byteChunks(utf8("event: é\ndata: 😀\ndata: e\u{301}\n\n"))))

    #expect(failure == nil)
    #expect(events == [ServerSentEvent(data: "😀\ne\u{301}", event: "é")])
  }

  @Test("a line that is not valid UTF-8 ends the sequence, and the events before it stand")
  func invalidUTF8EndsTheSequence() async throws {
    // A lone continuation byte is not valid UTF-8.
    let broken = utf8("data: a\n\ndata: ") + [0xFF] + utf8("\n\ndata: c\n\n")
    var iterator = SSEDecoder(byteChunks(broken)).makeAsyncIterator()

    #expect(try await iterator.next() == a)

    let failure = await failure { try await iterator.next() }
    #expect(isDecode(failure))
    #expect(failure?.underlying is UTF8.ValidationError)
    #expect(try await iterator.next() == nil)
    #expect(try await iterator.next() == nil)
  }

  @Test("a comment is validated too, because the stream as a whole must be UTF-8")
  func invalidUTF8InAComment() async {
    let (events, failure) = await drain(
      SSEDecoder(body([Data(utf8(": ") + [0xFF] + utf8("\ndata: a\n\n"))])))

    #expect(events.isEmpty)
    #expect(isDecode(failure))
    #expect(failure?.underlying is UTF8.ValidationError)
  }

  @Test("a failure travels through unchanged, and the iterator is finished after it")
  func failurePropagates() async throws {
    let timedOut = TransportError.transport(kind: .timedOut, underlying: nil)
    var iterator = SSEDecoder(failingBody("data: a\n\n", then: timedOut)).makeAsyncIterator()

    #expect(try await iterator.next() == a)
    #expect(await failure { try await iterator.next() }?.isTimeout == true)
    #expect(try await iterator.next() == nil)
  }

  @Test("a line past maxLineLength fails the sequence with the line splitter's own reason")
  func lineTooLong() async {
    let (events, failure) = await drain(SSEDecoder(body("data: abc\n\n"), maxLineLength: 8))

    #expect(events.isEmpty)
    #expect(failure?.underlying as? LineSplitterFailure == .lineTooLong(limit: 8))
  }

  @Test("a consumer cancelled while parked gets the base's cancellation, not a clean end")
  func cancelledWhileParked() async {
    // The base holds a frame with no blank line behind it, so the consumer is parked mid-frame when
    // the cancellation arrives.
    let (base, continuation) = AsyncStream.makeStream(of: Data.self)
    continuation.yield(Data("data: a\n".utf8))

    let consumer = Task.immediate {
      await drain(SSEDecoder(StreamedBody(base)))
    }
    consumer.cancel()
    let (events, failure) = await consumer.value

    #expect(events.isEmpty)
    #expect(isCancelled(failure))
  }

  @Test("an SSEDecoder erases to some AsyncSequence<ServerSentEvent, TransportError>")
  func erasure() async throws {
    let (base, continuation) = AsyncStream.makeStream(of: Data.self)
    continuation.yield(Data("data: a\n\ndata: b\n\n".utf8))
    continuation.finish()

    var result: [ServerSentEvent] = []
    // Iterated by hand rather than with `for try await`: an assertions build of the compiler asserts
    // on that loop over an erased typed-throws sequence.
    var iterator = erased(base).makeAsyncIterator()
    while let event = try await iterator.next() {
      result.append(event)
    }

    #expect(result == [a, b])
  }

  @Test("an SSEDecoder over a Sendable base is Sendable")
  func sendability() {
    let decoder: any Sendable = SSEDecoder(body())

    #expect(decoder is SSEDecoder<StreamedBody>)
  }
}
