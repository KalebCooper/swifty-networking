// `Data` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Synchronization

/// A bounded queue of chunks between a producer that pushes them and one reader that awaits them.
///
/// A transport that receives a body through callbacks, a `URLSessionDataDelegate` or a channel
/// handler, appends each chunk as it arrives and finishes when the body ends; the reader takes the
/// chunks through ``makeBody()`` as a ``StreamedBody``. The buffer holds what the producer is ahead
/// by, and keeps that bounded through a ``FlowControl``: when the buffered bytes exceed
/// `highWatermark` it suspends the producer, and when the reader has drained them to
/// `lowWatermark` it resumes it.
///
/// ```swift
/// let buffer = ChunkBuffer(control: task)
///
/// // The producer, as each chunk arrives, then once at the end.
/// buffer.append(chunk)
/// buffer.finish(throwing: nil)
///
/// // The reader.
/// for try await chunk in buffer.makeBody() {
///   handle(chunk)
/// }
/// ```
///
/// ## Flow Control
///
/// Only buffered bytes count: a chunk handed straight to a parked reader is never buffered and
/// moves nothing. ``FlowControl/suspend()`` is called once when an append takes the count above
/// `highWatermark` while the producer is running, and ``FlowControl/resume()`` once when a read
/// brings it to `lowWatermark` or below while the producer is suspended, so the two alternate and
/// the producer is never resumed more often than it was suspended. A `lowWatermark` of `0` resumes
/// only on an empty buffer. Both calls are made inside the buffer's critical section; see
/// ``FlowControl`` for what that asks of a conformer.
///
/// ## Ending
///
/// ``finish(throwing:)`` is the producer's last word. The reader still receives every chunk
/// buffered before it, then the failure once, or `nil`, and `nil` on every read after that. An
/// append or a second finish after it is ignored.
///
/// ## Cancellation
///
/// A reader whose task is cancelled while parked is woken with ``TransportError/cancelled``; the
/// buffer itself is untouched, and ``StreamedBody`` finishes the iterator that saw it. ``cancel()``
/// is the reader's side of ending: it drops every buffered chunk, ignores every later append and
/// finish, answers `nil` from then on, and calls ``FlowControl/cancel()`` when the producer was
/// still running, since whoever dropped the reader has no further use for it. A producer that had
/// already finished is left alone, so a body read to its end cancels nothing. The body
/// ``makeBody()`` returns calls ``cancel()`` when the last reference to it or to an iterator over
/// it is released, so a body dropped unread cancels the buffer the same way a reader that stops
/// mid-body does.
///
/// The buffer is read once: ``makeBody()`` hands out one body carrying the buffer's one
/// cancellation token, and that body makes one iterator. A second body, a second iterator, or a
/// second read in flight is a programming error and traps.
package final class ChunkBuffer: Sendable {
  /// What one read produces: the next chunk, `nil` at the end, or the failure the producer ended
  /// with.
  private typealias Outcome = Result<Data?, TransportError>

  /// A parked reader.
  private typealias Waiter = CheckedContinuation<Outcome, Never>

  /// Whether the producer may still append.
  private enum Phase {
    /// The producer is done; every buffered chunk is still delivered, then the failure or `nil`.
    case ended(TransportError?)
    /// Chunks may still arrive.
    case open
  }

  private struct State {
    var bufferedBytes = 0
    var chunks: ArraySlice<Data> = []
    var hasBody = false
    var hasIterator = false
    var phase = Phase.open
    var suspended = false
    var waiter: Waiter?

    /// The producer's last word, handed out once: a failure is reported to a single read, and the
    /// buffer reads as ended by `nil` after it. `nil` while the producer is still open.
    mutating func takeEnding() -> Outcome? {
      guard case .ended(let failure) = phase else { return nil }
      phase = .ended(nil)
      if let failure {
        return .failure(failure)
      }
      return .success(nil)
    }
  }

  /// Holds the buffer on behalf of a body or an iterator over it; releasing the last one cancels
  /// the buffer, which is how a dropped reader is noticed.
  private final class Reader: Sendable {
    let buffer: ChunkBuffer

    init(buffer: ChunkBuffer) {
      self.buffer = buffer
    }

    deinit {
      buffer.cancel()
    }
  }

  /// The sequence ``makeBody()`` wraps: each read is one ``ChunkBuffer/next()``.
  private struct Chunks: AsyncSequence, Sendable {
    typealias Element = Data
    typealias Failure = TransportError

    let reader: Reader

    struct AsyncIterator: AsyncIteratorProtocol {
      let reader: Reader

      func next(isolation actor: isolated (any Actor)?) async throws(TransportError) -> Data? {
        try await reader.buffer.next()
      }
    }

    func makeAsyncIterator() -> AsyncIterator {
      reader.buffer.claimIterator()
      return AsyncIterator(reader: reader)
    }
  }

  private let control: any FlowControl
  private let highWatermark: Int
  private let lowWatermark: Int
  private let state = Mutex(State())

  /// Creates an empty buffer over a producer.
  ///
  /// - Parameters:
  ///   - control: The producer to suspend and resume.
  ///   - highWatermark: The buffered byte count above which the producer is suspended.
  ///   - lowWatermark: The buffered byte count at or below which a suspended producer is resumed.
  ///     Neither watermark may be negative, and this one may not exceed `highWatermark`.
  package init(
    control: any FlowControl, highWatermark: Int = 512 * 1024, lowWatermark: Int = 128 * 1024
  ) {
    precondition(
      0 <= lowWatermark && lowWatermark <= highWatermark,
      "ChunkBuffer watermarks are 0 <= lowWatermark <= highWatermark")
    self.control = control
    self.highWatermark = highWatermark
    self.lowWatermark = lowWatermark
  }

  /// The chunks as a ``StreamedBody``, read through ``next()``.
  ///
  /// The body carries the buffer's one cancellation token: releasing it and every iterator over it
  /// calls ``cancel()``. A buffer hands out one body, and a second call is a programming error.
  ///
  /// - Returns: The body to read the chunks from.
  package func makeBody() -> StreamedBody {
    state.withLock { state in
      precondition(!state.hasBody, "ChunkBuffer hands out one body")
      state.hasBody = true
    }
    return StreamedBody(Chunks(reader: Reader(buffer: self)))
  }

  /// Records that the body's one iterator has been made, trapping on a second.
  private func claimIterator() {
    state.withLock { state in
      precondition(!state.hasIterator, "ChunkBuffer serves one reader")
      state.hasIterator = true
    }
  }

  /// Delivers one chunk to the reader, suspending the producer if the buffered bytes now exceed
  /// the high watermark.
  ///
  /// A chunk that arrives while the reader is parked goes straight to it and is never buffered.
  /// After ``finish(throwing:)`` or ``cancel()`` the chunk is dropped.
  ///
  /// - Parameter chunk: The bytes as the producer received them.
  package func append(_ chunk: Data) {
    let waiter: Waiter? = state.withLock { state in
      guard case .open = state.phase else { return nil }
      if let waiter = state.waiter.take() {
        return waiter
      }
      state.chunks.append(chunk)
      state.bufferedBytes += chunk.count
      if !state.suspended, state.bufferedBytes > highWatermark {
        state.suspended = true
        control.suspend()
      }
      return nil
    }
    waiter?.resume(returning: .success(chunk))
  }

  /// Ends the producer's side, with the failure that ended it or `nil` for a clean end.
  ///
  /// A reader parked on an empty buffer is woken with the ending at once; otherwise it is
  /// delivered after the last buffered chunk. A second call, or one after ``cancel()``, is ignored.
  ///
  /// - Parameter failure: What the reader throws after the last chunk, or `nil`.
  package func finish(throwing failure: TransportError?) {
    let wake: (Waiter, Outcome)? = state.withLock { state in
      guard case .open = state.phase else { return nil }
      state.phase = .ended(failure)
      // The ending is taken before the waiter is removed, so the two always move together: a
      // parked reader is never taken off the buffer without an ending to hand it, and the ending
      // is never spent with no reader to receive it.
      guard let waiter = state.waiter, let ending = state.takeEnding() else { return nil }
      state.waiter = nil
      return (waiter, ending)
    }
    if let (waiter, outcome) = wake {
      waiter.resume(returning: outcome)
    }
  }

  /// The next chunk, parking until one arrives when the buffer is empty.
  ///
  /// Taking a chunk resumes a suspended producer once the buffered bytes are at or below the low
  /// watermark. When the buffer is empty and finished, the answer is the failure once, then `nil`.
  ///
  /// - Returns: The next chunk, or `nil` when the producer has finished or the buffer was
  ///   cancelled.
  /// - Throws: ``TransportError/cancelled`` when the calling task is cancelled while parked or was
  ///   already cancelled on an empty buffer, and otherwise the failure the producer finished with.
  package func next() async throws(TransportError) -> Data? {
    let outcome: Outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: Waiter) in
        let decided: Outcome? = state.withLock { state in
          if let chunk = state.chunks.popFirst() {
            state.bufferedBytes -= chunk.count
            if state.suspended, state.bufferedBytes <= lowWatermark {
              state.suspended = false
              control.resume()
            }
            return .success(chunk)
          }
          if let ending = state.takeEnding() {
            return ending
          }
          // The cancellation flag is read under the same lock the handler removes the waiter under,
          // so a cancellation that landed before this point is answered here and never parks, and
          // one that lands after it finds the waiter to wake.
          if Task.isCancelled {
            return .failure(.cancelled)
          }
          // The buffer parks one reader: a second read arriving while one is parked would
          // overwrite the waiter and strand it. `next()` is callable without a body, so this is
          // where that invariant is held; it reports the misuse, it does not resolve it.
          precondition(state.waiter == nil, "ChunkBuffer serves one reader at a time")
          state.waiter = continuation
          return nil
        }
        if let decided {
          continuation.resume(returning: decided)
        }
      }
    } onCancel: {
      let waiter = state.withLock { $0.waiter.take() }
      waiter?.resume(returning: .failure(.cancelled))
    }
    return try outcome.get()
  }

  /// Ends the reader's side: drops every buffered chunk, ignores every later append and finish,
  /// and answers `nil` from then on.
  ///
  /// A producer still running is cancelled through ``FlowControl/cancel()``; one that has already
  /// finished is left alone, so this reaches the control at most once. ``makeBody()``'s body calls
  /// this when its last reference is released, so a transport rarely needs to.
  package func cancel() {
    let waiter: Waiter? = state.withLock { state in
      state.bufferedBytes = 0
      state.chunks = []
      if case .open = state.phase {
        control.cancel()
      }
      state.phase = .ended(nil)
      return state.waiter.take()
    }
    waiter?.resume(returning: .success(nil))
  }
}
