#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPCore
import HTTPTesting
import Testing

/// One record of a fixture stream.
private struct Record: Codable, Equatable, Sendable {
  let id: Int
  let name: String
}

/// A record whose key decodes only under a key decoding strategy.
private struct SnakeRecord: Codable, Equatable, Sendable {
  let firstName: String
}

/// The bytes of `text`.
private func utf8(_ text: String) -> [UInt8] { Array(text.utf8) }

/// A body that delivers each of `texts` as one chunk and then ends.
private func body(_ texts: String...) -> StreamedBody {
  StreamedBody(
    AsyncStream { continuation in
      for text in texts { continuation.yield(Data(text.utf8)) }
      continuation.finish()
    })
}

/// A body that delivers every byte of `text` as a chunk of its own, so every boundary in a fixture
/// falls between two arrivals.
private func byteChunks(_ text: String) -> StreamedBody {
  StreamedBody(
    AsyncStream { continuation in
      for byte in utf8(text) { continuation.yield(Data([byte])) }
      continuation.finish()
    })
}

/// A body that delivers `text` as one chunk and then fails instead of ending cleanly.
private func failingBody(_ text: String, then failure: TransportError) -> StreamedBody {
  StreamedBody(
    AsyncThrowingStream<Data, any Error> { continuation in
      continuation.yield(Data(text.utf8))
      continuation.finish(throwing: failure)
    })
}

/// Reads every value, returning them with the typed failure that ended the sequence, if one did.
private func drain<Base, Value>(_ decoder: NDJSONDecoder<Base, Value>) async -> (
  values: [Value], failure: TransportError?
) {
  var values: [Value] = []
  var iterator = decoder.makeAsyncIterator()
  do {
    while let value = try await iterator.next() {
      values.append(value)
    }
    return (values, nil)
  } catch {
    return (values, error)
  }
}

/// The records `text` decodes into, dropping how the sequence ended, whether it arrives as one
/// chunk or a byte at a time.
private func records(of text: String) async -> (whole: [Record], byByte: [Record]) {
  let whole = await drain(NDJSONDecoder(body(text), decoding: Record.self)).values
  let byByte = await drain(NDJSONDecoder(byteChunks(text), decoding: Record.self)).values
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
private func erased(_ base: AsyncStream<Data>) -> some AsyncSequence<Record, TransportError> {
  NDJSONDecoder(StreamedBody(base), decoding: Record.self)
}

private let first = Record(id: 1, name: "a")
private let second = Record(id: 2, name: "b")

@Suite("NDJSONDecoder", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct NDJSONDecoderTests {
  @Test(
    "each line of newline-delimited JSON decodes as one value",
    arguments: [
      ("{\"id\":1,\"name\":\"a\"}\n{\"id\":2,\"name\":\"b\"}\n", [first, second]),
      ("{\"id\":1,\"name\":\"a\"}\r\n{\"id\":2,\"name\":\"b\"}\r\n", [first, second]),
      ("{\"id\":1,\"name\":\"a\"}\n{\"id\":2,\"name\":\"b\"}", [first, second]),
      ("\n{\"id\":1,\"name\":\"a\"}\n\n{\"id\":2,\"name\":\"b\"}\n\n", [first, second]),
      ("{\"id\":1,\"name\":\"a\"}\n   \n\t\n{\"id\":2,\"name\":\"b\"}\n", [first, second]),
      ("", []),
      ("\n\n\n", []),
      ("   \n", []),
      ("  {\"id\":1,\"name\":\"a\"}  \n", [first]),
    ]
  )
  private func golden(input: String, expected: [Record]) async {
    let (whole, byByte) = await records(of: input)

    #expect(whole == expected)
    #expect(byByte == expected)
  }

  @Test("an NDJSON value straddling a chunk boundary decodes intact")
  func valueStraddlesAChunkBoundary() async {
    let (values, failure) = await drain(
      NDJSONDecoder(
        body("{\"id\":1,\"na", "me\":\"a\"}\n{\"id\"", ":2,\"name\":\"b\"}\n"),
        decoding: Record.self))

    #expect(failure == nil)
    #expect(values == [first, second])
  }

  @Test("a multibyte scalar inside a record survives the split and the decode")
  func multibyteScalar() async {
    let (values, failure) = await drain(
      NDJSONDecoder(byteChunks("{\"id\":1,\"name\":\"é😀\"}\n"), decoding: Record.self))

    #expect(failure == nil)
    #expect(values == [Record(id: 1, name: "é😀")])
  }

  @Test("a line the decoder rejects ends the sequence, and the values before it stand")
  func decodeFailureEndsTheSequence() async throws {
    var iterator = NDJSONDecoder(
      body("{\"id\":1,\"name\":\"a\"}\n{\"id\":\"two\"}\n{\"id\":3,\"name\":\"c\"}\n"),
      decoding: Record.self
    ).makeAsyncIterator()

    #expect(try await iterator.next() == first)

    let failure = await failure { try await iterator.next() }
    #expect(isDecode(failure))
    #expect(failure?.underlying is DecodingError)
    #expect(try await iterator.next() == nil)
    #expect(try await iterator.next() == nil)
  }

  @Test("a record cut off by the end of the stream is a decode failure, not a silent end")
  func truncatedFinalRecord() async {
    let (values, failure) = await drain(
      NDJSONDecoder(body("{\"id\":1,\"name\":\"a\"}\n{\"id\":2,\"na"), decoding: Record.self))

    #expect(values == [first])
    #expect(isDecode(failure))
  }

  @Test("a failure travels through unchanged, and the iterator is finished after it")
  func failurePropagates() async throws {
    let timedOut = TransportError.transport(kind: .timedOut, underlying: nil)
    var iterator = NDJSONDecoder(
      failingBody("{\"id\":1,\"name\":\"a\"}\n", then: timedOut),
      decoding: Record.self
    ).makeAsyncIterator()

    #expect(try await iterator.next() == first)
    #expect(await failure { try await iterator.next() }?.isTimeout == true)
    #expect(try await iterator.next() == nil)
  }

  @Test("the injected decoder is the one every line is read with")
  func injectedDecoder() async {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let (values, failure) = await drain(
      NDJSONDecoder(
        body("{\"first_name\":\"a\"}\n"), decoder: decoder, decoding: SnakeRecord.self))

    #expect(failure == nil)
    #expect(values == [SnakeRecord(firstName: "a")])
  }

  @Test("a line past maxLineLength fails the sequence with the line splitter's own reason")
  func lineTooLong() async {
    let (values, failure) = await drain(
      NDJSONDecoder(
        body("{\"id\":1,\"name\":\"a\"}\n"), decoding: Record.self, maxLineLength: 8))

    #expect(values.isEmpty)
    #expect(failure?.underlying as? LineSplitterFailure == .lineTooLong(limit: 8))
  }

  @Test("a consumer cancelled while parked gets the base's cancellation, not a clean end")
  func cancelledWhileParked() async {
    // The base holds a record with no terminator behind it, so the consumer is parked mid-line when
    // the cancellation arrives.
    let (base, continuation) = AsyncStream.makeStream(of: Data.self)
    continuation.yield(Data("{\"id\":1,\"name\":\"a\"}".utf8))

    let consumer = Task.immediate {
      await drain(NDJSONDecoder(StreamedBody(base), decoding: Record.self))
    }
    consumer.cancel()
    let (values, failure) = await consumer.value

    #expect(values.isEmpty)
    #expect(isCancelled(failure))
  }

  @Test("an NDJSONDecoder erases to some AsyncSequence<Value, TransportError>")
  func erasure() async throws {
    let (base, continuation) = AsyncStream.makeStream(of: Data.self)
    continuation.yield(Data("{\"id\":1,\"name\":\"a\"}\n{\"id\":2,\"name\":\"b\"}\n".utf8))
    continuation.finish()

    var result: [Record] = []
    // Iterated by hand rather than with `for try await`: an assertions build of the compiler asserts
    // on that loop over an erased typed-throws sequence.
    var iterator = erased(base).makeAsyncIterator()
    while let record = try await iterator.next() {
      result.append(record)
    }

    #expect(result == [first, second])
  }

  @Test("an NDJSONDecoder over a Sendable base is Sendable")
  func sendability() {
    let decoder: any Sendable = NDJSONDecoder(body(), decoding: Record.self)

    #expect(decoder is NDJSONDecoder<StreamedBody, Record>)
  }
}
