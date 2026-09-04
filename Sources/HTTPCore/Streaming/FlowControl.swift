/// A producer that a ``ChunkBuffer`` can pause, restart, and stop.
///
/// The buffer calls ``suspend()`` once when the bytes it holds exceed its high watermark and
/// ``resume()`` once when they have drained to its low watermark, and never calls either twice in
/// a row. It calls ``cancel()`` at most once, when its reader goes away while the producer is still
/// running, and calls nothing after it. A conformer stops delivering chunks after `suspend()`,
/// starts again after `resume()`, and stops for good after `cancel()`; a `URLSessionDataTask` or a
/// channel whose reads are switched off is the shape.
///
/// ```swift
/// struct ProducerControl: FlowControl {
///   weak var producer: Producer?
///
///   func cancel() { producer?.stop() }
///   func resume() { producer?.start() }
///   func suspend() { producer?.pause() }
/// }
///
/// let buffer = ChunkBuffer(control: ProducerControl(producer: producer))
/// ```
///
/// All three calls are made inside the buffer's critical section, so a conformer sees them in the
/// order they were decided and can never be left suspended by a `resume()` that overtook its
/// `suspend()`. The cost is a constraint on the conformer: each call returns promptly and neither
/// appends to, finishes, nor cancels the buffer from inside the call. A chunk a resumed producer
/// delivers on another thread waits for the section to end, which is the intended path.
package protocol FlowControl: Sendable {
  /// Stops delivery for good.
  ///
  /// The buffer calls this when its reader goes away with the producer still running, so a
  /// producer that has already finished is never cancelled and no buffer calls it twice. Neither
  /// ``resume()`` nor ``suspend()`` follows it.
  func cancel()

  /// Starts delivery again after ``suspend()``.
  func resume()

  /// Stops delivery until ``resume()``.
  func suspend()
}
