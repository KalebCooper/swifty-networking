// `Data` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Synchronization

/// A response body delivered as chunks of `Data`, failing only with ``TransportError``.
///
/// Every body this package streams is a `StreamedBody`: ``HTTPClient/stream(_:)`` returns one, a
/// ``Transport`` hands its own chunk sequence to one, and the decoders read one. It wraps
/// any `Sendable` sequence of `Data` and reads as one non-generic type, so a body can sit in a
/// property or cross an API without spelling the sequence beneath it. A chunk is whatever the
/// transport delivered in one read; nothing here splits, joins, or buffers one.
///
/// ```swift
/// let body = try await client.stream(Request(path: "/events"))
///
/// for try await chunk in body {
///   handle(chunk)
/// }
/// ```
///
/// ## Failures
///
/// Only the transport that made a base knows what its errors mean, so the mapping from the base's
/// failure to a ``TransportError`` is supplied at construction, and the default covers a base that
/// classifies nothing. Wrapping costs one closure call per chunk and nothing else: the base's
/// iterator is boxed once when iteration begins, nothing is buffered, and no task is started. See
/// <doc:Streaming>.
///
/// ```swift
/// let body = StreamedBody(source) { error in
///   TransportError.transport(kind: .connectivity, underlying: error)
/// }
/// ```
///
/// ## Cancellation
///
/// A consumer whose task is cancelled sees ``TransportError/cancelled`` from its next `next()` at
/// the latest, whatever the base does about cancellation, and never a clean end in cancellation's
/// place. Once `next()` has returned `nil` or thrown, the iterator is finished and releases the
/// base; dropping it mid-body does the same, so whatever was still fetching the body can stop. See
/// <doc:Streaming>.
///
/// ```swift
/// let reading = Task {
///   for try await chunk in body { handle(chunk) }
/// }
///
/// reading.cancel()  // The next read throws TransportError.cancelled.
/// ```
public struct StreamedBody: AsyncSequence, Sendable {
  /// One chunk of the body, as the transport delivered it.
  public typealias Element = Data
  /// The only error a read can throw; a failure of the base has been mapped by the time it
  /// surfaces.
  public typealias Failure = TransportError

  private let makeIterator: @Sendable () -> Iterator

  /// A body reading through `makeIterator`, whatever it wraps.
  private init(makeIterator: @escaping @Sendable () -> Iterator) {
    self.makeIterator = makeIterator
  }

  /// Wraps a sequence of chunks, reading its failures with the given mapping.
  ///
  /// The default mapping turns `CancellationError` into ``TransportError/cancelled``, passes a
  /// `TransportError` through unchanged, and wraps anything else in a transport failure of kind
  /// ``TransportFailureKind/other`` carrying the original error.
  ///
  /// - Parameters:
  ///   - base: The sequence to read chunks from.
  ///   - mapFailure: How a failure of the base reads as a ``TransportError``.
  public init<Base: AsyncSequence & Sendable>(
    _ base: Base,
    mapFailure: @escaping @Sendable (Base.Failure) -> TransportError = { transportError(from: $0) }
  ) where Base.Element == Data {
    makeIterator = { Iterator(base, mapFailure: mapFailure) }
  }

  /// An iterator over the base's chunks, applying the body's failure mapping.
  public func makeAsyncIterator() -> Iterator {
    makeIterator()
  }

  /// This body, reporting how it ended to `report` once, from the read that reached the end.
  ///
  /// The report runs inline in the consumer's `next()` after this body's own read returned `nil`
  /// or threw, carrying the bytes that iterator's reads returned and the failure, if any, and then
  /// the outcome is passed on unchanged. It runs once for the value, however many iterators are
  /// made over it, and never for a body dropped before it ended: nothing here runs on release,
  /// because a release can happen inside a buffer's critical section.
  ///
  /// - Parameter report: Receives the byte count and the failure that ended the body, or `nil`.
  /// - Returns: A body delivering the same chunks and the same outcome.
  package func reportingEnd(
    to report: @escaping @Sendable (_ bytesReceived: Int, _ failure: TransportError?) -> Void
  ) -> StreamedBody {
    let once = EndReport()
    return StreamedBody { Iterator(reporting: makeIterator(), through: once, to: report) }
  }

  /// The iterator over a ``StreamedBody``.
  ///
  /// It is not `Sendable`: it holds the base's iterator, which is in exclusive use by whichever
  /// task is reading it. The base's iterator is boxed, so copies of this iterator share it: read
  /// through one copy.
  public struct Iterator: AsyncIteratorProtocol {
    /// One chunk of the body.
    public typealias Element = Data
    /// The only error `next()` can throw.
    public typealias Failure = TransportError

    private let read: () async throws(TransportError) -> Data?

    init<Base: AsyncSequence>(
      _ base: Base, mapFailure: @escaping @Sendable (Base.Failure) -> TransportError
    ) where Base.Element == Data {
      // The closure captures the base's iterator in a box of its own. An `Optional` so the closure
      // can take it out for the duration of a read and put it back only when a chunk came out,
      // which leaves every other outcome finished with nothing to release. The closure carries no
      // isolation of its own: it runs on its caller's, so the isolation `next(isolation:)` receives
      // is the one the base is read under, and the box never crosses an isolation boundary.
      var iterator: Base.AsyncIterator? = base.makeAsyncIterator()
      read = { () throws(TransportError) in
        guard var current = iterator.take() else { return nil }
        if Task.isCancelled { throw .cancelled }

        let chunk: Data?
        do throws(Base.Failure) {
          chunk = try await current.next(isolation: #isolation)
        } catch {
          throw Task.isCancelled ? .cancelled : mapFailure(error)
        }

        guard let chunk else {
          if Task.isCancelled { throw .cancelled }
          return nil
        }
        iterator = current
        return chunk
      }
    }

    /// Wraps `inner`, counting the bytes it returns and reporting its end through `once`.
    init(
      reporting inner: Iterator, through once: EndReport,
      to report: @escaping @Sendable (Int, TransportError?) -> Void
    ) {
      // The inner iterator is captured the way a base's is: exclusively, by the closure that reads
      // it, on whatever isolation the read is called under.
      var inner = inner
      var received = 0
      read = { () throws(TransportError) in
        let chunk: Data?
        do throws(TransportError) {
          chunk = try await inner.next(isolation: #isolation)
        } catch {
          if once.claim() { report(received, error) }
          throw error
        }
        guard let chunk else {
          if once.claim() { report(received, nil) }
          return nil
        }
        received += chunk.count
        return chunk
      }
    }

    /// The next chunk, or `nil` when the base has ended or this iterator has already finished.
    ///
    /// - Throws: `TransportError.cancelled` when the calling task is cancelled; otherwise the
    ///   base's failure as the body's mapping reads it.
    public mutating func next(
      isolation actor: isolated (any Actor)? = #isolation
    ) async throws(TransportError) -> Data? {
      try await read()
    }
  }
}

/// The one report a body makes about its end, shared by every iterator over the body's value.
///
/// A finished iterator answers `nil` from then on, so without this a second iterator, or a second
/// read of a finished one, would report a second clean end for a body that ended once.
final class EndReport: Sendable {
  private let claimed = Atomic(false)

  /// Whether the caller is the first to reach the end, and so the one that reports it.
  func claim() -> Bool {
    claimed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing)
      .exchanged
  }
}

/// The mapping a body applies when no other one was supplied.
///
/// A default argument of a public initializer is checked as inlinable code, which is why this is
/// visible to one without being public itself.
@usableFromInline
func transportError<Failure: Error>(from failure: Failure) -> TransportError {
  if let error = failure as? TransportError {
    return error
  }
  if failure is CancellationError {
    return .cancelled
  }
  return .transport(kind: .other, underlying: failure)
}
