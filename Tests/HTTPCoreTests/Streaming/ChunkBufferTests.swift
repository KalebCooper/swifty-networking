#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPCore
import HTTPTesting
import Testing

/// One read, with its typed failure carried as a value so a task can return it.
private func read(_ buffer: ChunkBuffer) async -> Result<Data?, TransportError> {
  do throws(TransportError) {
    return .success(try await buffer.next())
  } catch {
    return .failure(error)
  }
}

/// One read through an iterator a test holds in a variable, so the test can release the iterator
/// where it means to rather than where the scope ends.
private func read(
  _ iterator: inout StreamedBody.Iterator?,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws -> Data? {
  var current = try #require(iterator, sourceLocation: sourceLocation)
  let chunk = try await current.next()
  iterator = current
  return chunk
}

/// Whether a read ended the buffer with `nil`.
private func ended(_ outcome: Result<Data?, TransportError>) -> Bool {
  if case .success(nil) = outcome { true } else { false }
}

/// Whether a read threw ``TransportError/cancelled``.
private func cancelled(_ outcome: Result<Data?, TransportError>) -> Bool {
  if case .failure(.cancelled) = outcome { true } else { false }
}

/// Whether a read threw a timeout.
private func timedOut(_ outcome: Result<Data?, TransportError>) -> Bool {
  if case .failure(let error) = outcome { error.isTimeout } else { false }
}

/// Reads every chunk of `body`, returning them with the failure that ended it, if one did.
private func drain(_ body: StreamedBody) async -> (received: [Data], failure: TransportError?) {
  var chunks: [Data] = []
  do throws(TransportError) {
    for try await chunk in body {
      chunks.append(chunk)
    }
    return (chunks, nil)
  } catch {
    return (chunks, error)
  }
}

/// The chunk a writer appends at `index`: one to seventeen bytes, each the index's low byte, so
/// a reader can check both the order and the byte count of what it received.
private func chunk(at index: Int) -> Data {
  Data(repeating: UInt8(truncatingIfNeeded: index), count: index % 17 + 1)
}

private let timeout = TransportError.transport(kind: .timedOut, underlying: nil)

@Suite("ChunkBuffer", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct ChunkBufferTests {
  @Test("crossing the high watermark suspends the producer once")
  func crossingTheHighWatermarkSuspendsOnce() {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control, highWatermark: 4, lowWatermark: 1)

    for _ in 0..<4 {
      buffer.append(Data([1]))
    }
    #expect(control.calls == [])

    buffer.append(Data([1]))
    #expect(control.calls == [.suspend])

    buffer.append(Data([1]))
    buffer.append(Data([1]))
    #expect(control.calls == [.suspend])
  }

  @Test("draining below the low watermark resumes the producer once")
  func drainingBelowTheLowWatermarkResumesOnce() async throws {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control, highWatermark: 4, lowWatermark: 1)
    for _ in 0..<7 {
      buffer.append(Data([1]))
    }

    // Seven bytes down to two: still above the low watermark.
    for _ in 0..<5 {
      _ = try await buffer.next()
    }
    #expect(control.calls == [.suspend])

    // Two bytes down to one: at the low watermark.
    _ = try await buffer.next()
    #expect(control.calls == [.suspend, .resume])

    // One byte down to none: already resumed.
    _ = try await buffer.next()
    #expect(control.calls == [.suspend, .resume])
  }

  @Test("watermarks may be equal")
  func watermarksMayBeEqual() async throws {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control, highWatermark: 4, lowWatermark: 4)

    buffer.append(Data(count: 4))
    #expect(control.calls == [])

    buffer.append(Data([1]))
    #expect(control.calls == [.suspend])

    #expect(try await buffer.next()?.count == 4)
    #expect(control.calls == [.suspend, .resume])
  }

  @Test("the high watermark defaults to 512 KiB")
  func theHighWatermarkDefaultsTo512KiB() {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control)

    buffer.append(Data(count: 524_288))
    #expect(control.calls == [])

    buffer.append(Data([1]))
    #expect(control.calls == [.suspend])
  }

  @Test("the low watermark defaults to 128 KiB")
  func theLowWatermarkDefaultsTo128KiB() async throws {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control)

    // 512 KiB and one byte buffered, in three chunks the reader takes back one at a time.
    buffer.append(Data(count: 393_216))
    buffer.append(Data([1]))
    buffer.append(Data(count: 131_072))
    #expect(control.calls == [.suspend])

    // 131_073 bytes left: one byte above the watermark.
    #expect(try await buffer.next()?.count == 393_216)
    #expect(control.calls == [.suspend])

    // 131_072 bytes left: at it.
    #expect(try await buffer.next()?.count == 1)
    #expect(control.calls == [.suspend, .resume])
  }

  @Test("a producer is never resumed more often than it was suspended")
  func neverResumedMoreOftenThanSuspended() async throws {
    // A writer and a reader race over ten thousand chunks. The high watermark sits below the
    // largest chunk, so at least one append suspends however fast the reader keeps up, and the
    // control's log is the only evidence: a resume can only ever follow the suspend it answers.
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control, highWatermark: 16, lowWatermark: 4)
    let count = 10_000

    async let received = drain(buffer.makeBody())
    for index in 0..<count {
      buffer.append(chunk(at: index))
    }
    buffer.finish(throwing: nil)
    let (chunks, failure) = await received

    #expect(chunks == (0..<count).map { chunk(at: $0) })
    #expect(failure == nil)

    let calls = control.calls
    let suspends = calls.count { $0 == .suspend }
    let resumes = calls.count { $0 == .resume }
    #expect(suspends >= 1)
    #expect(resumes <= suspends)
    #expect(
      calls
        == Array(repeating: [CountingControl.Call.suspend, .resume], count: calls.count / 2)
        .flatMap { $0 })
  }

  @Test("finishing wakes a reader parked on an empty buffer with nil")
  func finishingWakesAParkedReaderWithNil() async {
    let buffer = ChunkBuffer(control: CountingControl())

    // `Task.immediate` runs the reader synchronously up to its first suspension, so it is parked
    // before the finish below.
    let reader = Task.immediate { await read(buffer) }
    buffer.finish(throwing: nil)

    #expect(ended(await reader.value))
  }

  @Test("finishing with a failure wakes a parked reader with it")
  func finishingWithAFailureWakesAParkedReader() async {
    let buffer = ChunkBuffer(control: CountingControl())

    let reader = Task.immediate { await read(buffer) }
    buffer.finish(throwing: timeout)

    #expect(timedOut(await reader.value))
    #expect(ended(await read(buffer)))
  }

  @Test("a failure reaches the reader after every buffered chunk")
  func failureReachesTheReaderAfterEveryBufferedChunk() async throws {
    let buffer = ChunkBuffer(control: CountingControl())
    buffer.append(Data([1]))
    buffer.append(Data([2]))
    buffer.finish(throwing: timeout)

    #expect(try await buffer.next() == Data([1]))
    #expect(try await buffer.next() == Data([2]))
    #expect(timedOut(await read(buffer)))
    #expect(try await buffer.next() == nil)
  }

  @Test("a failure reaches a body's reader as itself")
  func failureReachesABody() async {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control)
    buffer.append(Data([1]))
    buffer.finish(throwing: timeout)

    let (received, failure) = await drain(buffer.makeBody())

    #expect(received == [Data([1])])
    #expect(failure?.isTimeout == true)

    // The producer ended the body itself, so releasing it at the end of the drain cancels nothing.
    #expect(control.calls == [])
  }

  @Test("cancelling the reader drops what is buffered and ignores later appends")
  func cancellingDropsBufferedChunksAndIgnoresLaterAppends() async throws {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control, highWatermark: 1, lowWatermark: 0)
    buffer.append(Data([1]))
    buffer.append(Data([2]))
    #expect(control.calls == [.suspend])

    buffer.cancel()
    buffer.append(Data([3]))
    buffer.finish(throwing: timeout)

    #expect(try await buffer.next() == nil)
    #expect(try await buffer.next() == nil)
    #expect(control.calls == [.suspend, .cancel])
  }

  @Test("cancelling wakes a parked reader with nil")
  func cancellingWakesAParkedReaderWithNil() async {
    let buffer = ChunkBuffer(control: CountingControl())

    let reader = Task.immediate { await read(buffer) }
    buffer.cancel()

    #expect(ended(await reader.value))
  }

  @Test("cancelling a running producer cancels it once")
  func cancellingARunningProducerCancelsItOnce() {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control)
    buffer.append(Data([1]))

    buffer.cancel()
    #expect(control.calls == [.cancel])

    buffer.cancel()
    #expect(control.calls == [.cancel])
  }

  @Test("cancelling a finished producer leaves it alone")
  func cancellingAFinishedProducerLeavesItAlone() {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control)
    buffer.append(Data([1]))
    buffer.finish(throwing: nil)

    buffer.cancel()

    #expect(control.calls == [])
  }

  @Test("concurrent cancels reach the producer exactly once")
  func concurrentCancelsReachTheProducerExactlyOnce() async {
    // Sixty-four callers cancel at once, and the control's log is the only evidence that the
    // decision to cancel was taken inside one critical section rather than by whoever arrived
    // first.
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control)
    buffer.append(Data([1]))

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<64 {
        group.addTask { buffer.cancel() }
      }
    }

    #expect(control.calls == [.cancel])
  }

  @Test("a body drained to its end never cancels the producer")
  func aDrainedBodyNeverCancelsTheProducer() async throws {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control)
    var body: StreamedBody? = buffer.makeBody()
    var iterator: StreamedBody.Iterator? = body?.makeAsyncIterator()
    buffer.append(Data([1]))
    buffer.finish(throwing: nil)

    let chunk = try await read(&iterator)
    #expect(chunk == Data([1]))
    let ending = try await read(&iterator)
    #expect(ending == nil)

    iterator = nil
    body = nil

    #expect(control.calls == [])
  }

  @Test("the body and its iterator hold one cancellation token between them")
  func theBodyAndItsIteratorHoldOneToken() async throws {
    let buffer = ChunkBuffer(control: CountingControl())
    var body: StreamedBody? = buffer.makeBody()
    var iterator: StreamedBody.Iterator? = body?.makeAsyncIterator()
    buffer.append(Data([1]))

    let chunk = try await read(&iterator)
    #expect(chunk == Data([1]))

    // The body still holds the token, so releasing the iterator cancels nothing.
    iterator = nil
    buffer.append(Data([2]))
    #expect(try await buffer.next() == Data([2]))

    body = nil
    buffer.append(Data([3]))
    #expect(try await buffer.next() == nil)
  }

  @Test("chunks are yielded in the order appended")
  func chunksAreYieldedInOrder() async throws {
    let buffer = ChunkBuffer(control: CountingControl())
    for byte in UInt8(0)..<50 {
      buffer.append(Data([byte]))
    }
    buffer.finish(throwing: nil)

    let (received, failure) = await drain(buffer.makeBody())

    #expect(received == (0..<50).map { Data([UInt8($0)]) })
    #expect(failure == nil)
  }

  @Test("a chunk appended while the reader is parked is handed over unbuffered")
  func parkedReaderIsHandedTheChunk() async throws {
    // A high watermark of zero suspends on any buffered byte, so a call on the control here would
    // mean the chunk was buffered on its way to the reader.
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control, highWatermark: 0, lowWatermark: 0)

    let reader = Task.immediate { await read(buffer) }
    buffer.append(Data([7]))

    #expect(try await reader.value.get() == Data([7]))
    #expect(control.calls == [])

    buffer.append(Data([8]))
    #expect(control.calls == [.suspend])
  }

  @Test("a reader whose task is cancelled while parked is woken with cancelled")
  func cancelledWhileParked() async throws {
    let buffer = ChunkBuffer(control: CountingControl())

    let reader = Task.immediate { await read(buffer) }
    reader.cancel()
    #expect(cancelled(await reader.value))

    // The buffer itself is untouched by the reader's cancellation.
    buffer.append(Data([1]))
    #expect(try await buffer.next() == Data([1]))
  }

  @Test("a reader already cancelled on arrival at an empty buffer is refused")
  func cancelledOnArrival() async throws {
    let buffer = ChunkBuffer(control: CountingControl())

    // A task added to an already-cancelled group starts cancelled, which is deterministic where
    // racing a `cancel()` fired alongside it is not.
    let outcome = await withTaskGroup(of: Result<Data?, TransportError>.self) { group in
      group.cancelAll()
      group.addTask { await read(buffer) }
      return await group.next()
    }

    #expect(cancelled(try #require(outcome)))
  }

  @Test("releasing a body and its iterator mid-body cancels the buffer")
  func releasingTheBodyMidBodyCancels() async throws {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control)
    buffer.append(Data([1]))
    buffer.append(Data([2]))

    var body: StreamedBody? = buffer.makeBody()
    var iterator: StreamedBody.Iterator? = body?.makeAsyncIterator()
    let chunk = try await read(&iterator)
    #expect(chunk == Data([1]))

    #expect(control.calls == [])
    iterator = nil
    body = nil

    #expect(control.calls == [.cancel])
    buffer.append(Data([3]))
    #expect(try await buffer.next() == nil)
  }

  @Test("releasing a body unread cancels the buffer")
  func releasingAnUnreadBodyCancels() async throws {
    let control = CountingControl()
    let buffer = ChunkBuffer(control: control)

    var body: StreamedBody? = buffer.makeBody()
    _ = body

    #expect(control.calls == [])
    body = nil

    #expect(control.calls == [.cancel])
    buffer.append(Data([1]))
    #expect(try await buffer.next() == nil)
  }

  @Test("an append or a second finish after finishing is ignored")
  func appendsAndFinishesAfterFinishingAreIgnored() async throws {
    let buffer = ChunkBuffer(control: CountingControl())
    buffer.append(Data([1]))
    buffer.finish(throwing: nil)
    buffer.append(Data([2]))
    buffer.finish(throwing: timeout)

    #expect(try await buffer.next() == Data([1]))
    #expect(try await buffer.next() == nil)
  }
}
