#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPCore
import HTTPTesting
import Synchronization
import Testing

/// An error the default mapping does not recognize.
private struct Foreign: Error, Equatable {}

/// A base whose failure type is already `TransportError`. It yields `chunks`, then ends with
/// `failure` when there is one.
private struct TypedChunks: AsyncSequence, Sendable {
  typealias Element = Data
  typealias Failure = TransportError

  var chunks: [Data]
  var failure: TransportError?

  struct AsyncIterator: AsyncIteratorProtocol {
    var chunks: ArraySlice<Data>
    var failure: TransportError?

    mutating func next(isolation actor: isolated (any Actor)?) async throws(TransportError)
      -> Data?
    {
      if let chunk = chunks.popFirst() { return chunk }
      if let failure = failure.take() { throw failure }
      return nil
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(chunks: chunks[...], failure: failure)
  }
}

/// A base over `any Error` that yields `chunks` and then finishes with `failure`, or cleanly
/// without one.
private func throwingChunks(_ chunks: [Data], then failure: (any Error)? = nil)
  -> AsyncThrowingStream<Data, any Error>
{
  AsyncThrowingStream { continuation in
    for chunk in chunks {
      continuation.yield(chunk)
    }
    continuation.finish(throwing: failure)
  }
}

/// A base that never fails, yielding `chunks` and then finishing.
private func plainChunks(_ chunks: [Data]) -> AsyncStream<Data> {
  AsyncStream { continuation in
    for chunk in chunks {
      continuation.yield(chunk)
    }
    continuation.finish()
  }
}

/// The chunks of `texts`, as `Data`.
private func chunked(_ texts: String...) -> [Data] {
  texts.map { Data($0.utf8) }
}

/// Reads every chunk, returning them with the typed failure that ended the body, if one did.
private func drain(_ body: StreamedBody) async -> (received: [Data], failure: TransportError?) {
  var chunks: [Data] = []
  var iterator = body.makeAsyncIterator()
  do {
    while let chunk = try await iterator.next() {
      chunks.append(chunk)
    }
    return (chunks, nil)
  } catch {
    return (chunks, error)
  }
}

/// Whether the failure is ``TransportError/cancelled``.
private func isCancelled(_ error: TransportError?) -> Bool {
  if case .some(.cancelled) = error { true } else { false }
}

/// The kind and underlying error of a transport failure.
private func transportFailure(_ error: TransportError?) -> (
  kind: TransportFailureKind, underlying: (any Error)?
)? {
  if case .some(.transport(let kind, let underlying)) = error { (kind, underlying) } else { nil }
}

/// A base that answers each read with `[1]` when the isolation it was handed is the main actor and
/// `[0]` otherwise, so a test can see which isolation reached it.
private struct IsolationProbe: AsyncSequence, Sendable {
  typealias Element = Data
  typealias Failure = TransportError

  struct AsyncIterator: AsyncIteratorProtocol {
    var remaining = 1

    mutating func next(isolation actor: isolated (any Actor)?) async throws(TransportError)
      -> Data?
    {
      guard remaining > 0 else { return nil }
      remaining -= 1
      return Data([actor === MainActor.shared ? 1 : 0])
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator()
  }
}

/// Counts how many of its iterators have been released.
///
/// A live transport stops fetching when the consumer of its body is gone, and the only thing
/// ``StreamedBody`` can do about that is let go of the base's iterator. This base makes that
/// release visible: each iterator holds a token whose `deinit` counts, so a test can prove the base
/// saw its reader leave.
private final class ReleaseCounter: Sendable {
  private let count = Mutex(0)

  var released: Int { count.withLock { $0 } }

  func release() {
    count.withLock { $0 += 1 }
  }
}

/// A base that never ends on its own and reports the release of each iterator to a counter.
private struct WatchedChunks: AsyncSequence, Sendable {
  typealias Element = Data
  typealias Failure = TransportError

  let counter: ReleaseCounter

  /// Reports its release to the counter when it is deallocated.
  final class Token {
    let counter: ReleaseCounter

    init(counter: ReleaseCounter) {
      self.counter = counter
    }

    deinit {
      counter.release()
    }
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    let token: Token

    mutating func next(isolation actor: isolated (any Actor)?) async throws(TransportError)
      -> Data?
    {
      Data([1])
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(token: Token(counter: counter))
  }
}

/// One NDJSON record.
private struct Record: Decodable, Equatable, Sendable {
  let id: Int
}

@Suite("StreamedBody", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct StreamedBodyTests {
  @Test("chunks pass through in order, as given, and the body ends when the base does")
  func passThrough() async {
    let base = [Data([UInt8](0...255)), Data(), Data([0x7B, 0x22, 0x61, 0x22, 0x7D])]
    let (received, failure) = await drain(StreamedBody(plainChunks(base)))

    #expect(received == base)
    #expect(failure == nil)
  }

  @Test("an empty base ends at once")
  func emptyBase() async {
    let (received, failure) = await drain(StreamedBody(plainChunks([])))

    #expect(received.isEmpty)
    #expect(failure == nil)
  }

  @Test("a base that already speaks TransportError passes its chunks through")
  func typedBase() async {
    let (received, failure) = await drain(
      StreamedBody(TypedChunks(chunks: chunked("a", "b"), failure: nil)))

    #expect(received == chunked("a", "b"))
    #expect(failure == nil)
  }

  @Test("a failure mid-body surfaces unchanged after the chunks before it")
  func midBodyFailure() async {
    let timedOut = TransportError.transport(kind: .timedOut, underlying: nil)
    let (received, failure) = await drain(
      StreamedBody(TypedChunks(chunks: chunked("first", "second"), failure: timedOut)))

    #expect(received == chunked("first", "second"))
    #expect(transportFailure(failure)?.kind == .timedOut)
    #expect(transportFailure(failure)?.underlying == nil)
  }

  @Test("a failure from the base reaches the reader mapped into a transport error")
  func foreignFailureIsMapped() async {
    let (received, failure) = await drain(
      StreamedBody(throwingChunks(chunked("half"), then: Foreign())))

    #expect(received == chunked("half"))
    #expect(transportFailure(failure)?.kind == .other)
    #expect(transportFailure(failure)?.underlying as? Foreign == Foreign())
  }

  @Test("a base that throws CancellationError is reported as cancelled")
  func baseCancellationError() async {
    let (received, failure) = await drain(
      StreamedBody(throwingChunks(chunked("a", "b"), then: CancellationError())))

    #expect(received == chunked("a", "b"))
    #expect(isCancelled(failure))
  }

  @Test("a TransportError thrown by an untyped base passes through unchanged")
  func untypedTransportErrorPassesThrough() async {
    let timedOut = TransportError.transport(kind: .timedOut, underlying: nil)
    let (received, failure) = await drain(
      StreamedBody(throwingChunks(chunked("nine"), then: timedOut)))

    #expect(received == chunked("nine"))
    #expect(failure?.isTimeout == true)
  }

  @Test("a supplied mapping decides what a base failure means")
  func customMapping() async {
    let body = StreamedBody(throwingChunks(chunked("one"), then: Foreign())) { error in
      .transport(kind: .connectivity, underlying: error)
    }
    let (received, failure) = await drain(body)

    #expect(received == chunked("one"))
    #expect(transportFailure(failure)?.kind == .connectivity)
    #expect(transportFailure(failure)?.underlying as? Foreign == Foreign())
  }

  @Test("a failure is reported once, and the iterator is finished afterwards")
  func failureReportedOnce() async throws {
    let connectivity = TransportError.transport(kind: .connectivity, underlying: nil)
    var iterator = StreamedBody(TypedChunks(chunks: [], failure: connectivity))
      .makeAsyncIterator()

    let first = await failure { try await iterator.next() }
    #expect(transportFailure(first)?.kind == .connectivity)
    #expect(try await iterator.next() == nil)
    #expect(try await iterator.next() == nil)
  }

  @Test("a finished iterator keeps answering nil")
  func finishedStaysFinished() async throws {
    var iterator = StreamedBody(plainChunks(chunked("only"))).makeAsyncIterator()

    #expect(try await iterator.next() == Data("only".utf8))
    #expect(try await iterator.next() == nil)
    #expect(try await iterator.next() == nil)
  }

  @Test("each iterator over a re-iterable base reads it from the start")
  func independentIteratorsOverAReIterableBase() async {
    let body = StreamedBody(TypedChunks(chunks: chunked("a", "b", "c"), failure: nil))

    let first = await drain(body)
    let second = await drain(body)

    #expect(first.received == chunked("a", "b", "c"))
    #expect(second.received == chunked("a", "b", "c"))
  }

  @Test("a consumer already cancelled on arrival is refused before the base is read")
  func cancelledOnArrival() async throws {
    // A task added to an already-cancelled group starts cancelled, which is deterministic where
    // racing a `cancel()` fired alongside it is not.
    let outcome = await withTaskGroup(of: (received: [Data], failure: TransportError?).self) {
      group in
      group.cancelAll()
      group.addTask { await drain(StreamedBody(plainChunks(chunked("a", "b", "c")))) }
      return await group.next()
    }

    let (received, failure) = try #require(outcome)
    #expect(received.isEmpty)
    #expect(isCancelled(failure))
  }

  @Test("a consumer cancelled while parked on an empty base gets cancelled, not a clean end")
  func cancelledWhileParked() async {
    // `AsyncStream` answers a cancelled consumer with `nil`, the answer this test must not see.
    let (stream, _) = AsyncStream.makeStream(of: Data.self)

    // `Task.immediate` runs synchronously up to the first suspension, the base's parked `next`, so
    // the cancellation below reaches a consumer that is already waiting.
    let consumer = Task.immediate { await drain(StreamedBody(stream)) }
    consumer.cancel()
    let (received, failure) = await consumer.value

    #expect(received.isEmpty)
    #expect(isCancelled(failure))
  }

  @Test("a finished iterator answers nil even on a cancelled task")
  func finishedBeatsCancellation() async {
    let (gate, _) = AsyncStream.makeStream(of: Data.self)

    // The consumer finishes its iterator synchronously, then parks on an unrelated empty stream, so
    // the cancellation below arrives while it is parked and the last read runs on a cancelled task.
    let consumer = Task.immediate {
      var iterator = StreamedBody(plainChunks(chunked("one"))).makeAsyncIterator()
      var answers: [Data?] = []
      answers.append(try? await iterator.next())
      answers.append(try? await iterator.next())
      for await _ in gate {}
      answers.append(try? await iterator.next())
      return answers
    }
    consumer.cancel()

    #expect(await consumer.value == [Data("one".utf8), nil, nil])
  }

  @Test("dropping the iterator mid-body cancels the base")
  func droppingTheIteratorReleasesTheBase() async throws {
    // Ten readers each take one chunk of a body that never ends and then meet on a latch, so every
    // iterator is still alive when the last reader arrives and the ten drop together. Without the
    // latch a reader can finish before the next one starts, and ten releases counted one at a time
    // say nothing about a release under contention.
    let counter = ReleaseCounter()
    let latch = Latch()
    let readers = 10

    let read = await withTaskGroup(of: Int.self) { group in
      for _ in 0..<readers {
        group.addTask {
          var iterator = StreamedBody(WatchedChunks(counter: counter)).makeAsyncIterator()
          let chunk = try? await iterator.next()
          latch.arrive()
          await latch.wait(forCount: readers)
          return chunk == nil ? 0 : 1
        }
      }
      return await group.reduce(0, +)
    }

    #expect(read == readers)
    #expect(counter.released == readers)
  }

  @Test("the caller's isolation reaches the base")
  @MainActor
  func isolationForwarded() async throws {
    var iterator = StreamedBody(IsolationProbe()).makeAsyncIterator()

    #expect(try await iterator.next() == Data([1]))
  }

  @Test("a nonisolated caller reaches the base with no isolation")
  func noIsolationForwarded() async throws {
    var iterator = StreamedBody(IsolationProbe()).makeAsyncIterator()

    #expect(try await iterator.next() == Data([0]))
  }

  @Test("an isolation passed explicitly reaches the base")
  func explicitIsolationForwarded() async throws {
    var iterator = StreamedBody(IsolationProbe()).makeAsyncIterator()

    #expect(try await iterator.next(isolation: MainActor.shared) == Data([1]))
  }

  @Test("copies of an iterator share the base, so a read through one advances the other")
  func copiesShareBase() async throws {
    var first = StreamedBody(TypedChunks(chunks: chunked("a", "b", "c"), failure: nil))
      .makeAsyncIterator()
    var second = first

    #expect(try await first.next() == Data("a".utf8))
    #expect(try await second.next() == Data("b".utf8))
    #expect(try await first.next() == Data("c".utf8))
    #expect(try await second.next() == nil)
  }

  @Test("a StreamedBody is Sendable")
  func sendability() {
    let body: any Sendable = StreamedBody(plainChunks([]))

    #expect(body is StreamedBody)
  }

  @Test("LineSplitter reads a StreamedBody")
  func lineSplitter() async throws {
    var lines: [String] = []
    for try await line in LineSplitter(StreamedBody(plainChunks(chunked("one\r\ntwo\nthree")))) {
      lines.append(String(decoding: line.bytes, as: UTF8.self))
    }

    #expect(lines == ["one", "two", "three"])
  }

  @Test("NDJSONDecoder reads a StreamedBody")
  func ndjsonDecoder() async throws {
    var records: [Record] = []
    let decoder = NDJSONDecoder(
      StreamedBody(plainChunks(chunked("{\"id\":1}\n{\"id\":2}\n"))), decoding: Record.self)
    for try await record in decoder {
      records.append(record)
    }

    #expect(records == [Record(id: 1), Record(id: 2)])
  }

  @Test("SSEDecoder reads a StreamedBody")
  func sseDecoder() async throws {
    var events: [(event: String, data: String)] = []
    let body = StreamedBody(plainChunks(chunked("event: tick\ndata: 1\n\ndata: 2\n\n")))
    for try await event in SSEDecoder(body) {
      events.append((event.event, event.data))
    }

    #expect(events.map(\.event) == ["tick", "message"])
    #expect(events.map(\.data) == ["1", "2"])
  }
}
