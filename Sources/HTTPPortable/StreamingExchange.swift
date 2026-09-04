// The exchange reads an AsyncHTTPClient response body, which exists only behind the
// `HTTPPortable` trait, so it compiles only where the rest of the target does.
#if HTTPPortable

import AsyncHTTPClient
import HTTPCore
import HTTPTypes
import NIOCore
import NIOFoundationCompat
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// One streamed exchange: a task that sends the request, hands the response to the caller awaiting
/// it, and reads the body into a `ChunkBuffer` one buffer at a time.
///
/// ``AsyncHTTPClientTransport/stream(_:body:options:)`` makes one of these per call and gives it
/// the exchange to run through ``start(_:failure:)``, which runs in a task of the exchange's own:
/// the client's `execute` returns once the status and header fields are known, and the body is a
/// sequence the client reads from the connection only as it is pulled, so something has to keep
/// pulling after `stream` has returned. The response is answered once, through ``response()``,
/// from whichever settles it first: ``deliver(head:body:)`` with the status and header fields, or
/// the failure the task ended with when the request produced no response at all. Every buffer
/// read after that is appended as one chunk, and the end of the body finishes the buffer with
/// `nil` or the failure that ended it, so a failure after the response reaches the reader through
/// the body and never through the call.
///
/// ```swift
/// let exchange = StreamingExchange()
/// exchange.start {
///   let response = try await client.execute(request, deadline: .distantFuture)
///   try await exchange.deliver(head: head(of: response), body: response.body)
/// } failure: { error in
///   failure(from: error)
/// }
///
/// let head = try await exchange.response()
/// for try await chunk in exchange.makeBody() {
///   handle(chunk)
/// }
/// ```
///
/// The buffer's flow control is a ``PumpControl``: when the reader falls behind by more than the
/// buffer's high watermark the task stops pulling, which stops the client reading from the
/// connection, and it pulls again once the reader has caught up. Dropping the body cancels the
/// task, which cancels the client's request and closes its connection, and a file body still
/// being sent is closed with it, because the task is what holds the file open.
package final class StreamingExchange: Sendable {
  /// The status and header fields of a response, settled before its body.
  package struct Head: Sendable {
    /// The response header fields, complete.
    package let headers: HTTPFields

    /// The response status, as the server sent it.
    package let status: HTTPResponse.Status

    /// Creates a head.
    ///
    /// - Parameters:
    ///   - headers: The response header fields.
    ///   - status: The response status.
    package init(headers: HTTPFields, status: HTTPResponse.Status) {
      self.headers = headers
      self.status = status
    }
  }

  /// What the caller awaiting the response receives: the status and header fields, or the failure
  /// that stood in for them.
  private typealias Answer = Result<Head, TransportError>

  /// A caller parked on ``response()``.
  private typealias Waiter = CheckedContinuation<Answer, Never>

  private struct State {
    var answer: Answer?
    var waiter: Waiter?
  }

  private let buffer: ChunkBuffer
  private let control: PumpControl
  private let state = Mutex(State())

  /// Creates an exchange whose buffer pauses, restarts, and stops the reading task through
  /// `control`.
  ///
  /// - Parameter control: The control the buffer drives and the task waits on; defaults to a new
  ///   one.
  package init(control: PumpControl = PumpControl()) {
    self.control = control
    buffer = ChunkBuffer(control: control)
  }

  /// Runs `run` in a task of the exchange's own, and ends the exchange with its failure when it
  /// throws.
  ///
  /// `run` sends the request and calls ``deliver(head:body:)`` with the response. A `run` that
  /// throws before delivering fails the response; one that throws after it, when the body failed
  /// part-way, ends the body with the failure instead. A `run` that returns without delivering is
  /// a mistake in the transport, and fails the response as
  /// ``/HTTPCore/TransportFailureKind/other`` with nothing underlying rather than parking the
  /// caller forever, so every `run` answers ``response()``. Either way the task is the whole
  /// exchange: cancelling it, through ``cancel()`` or through the buffer's control when the body
  /// is dropped, is what stops the request.
  ///
  /// - Parameters:
  ///   - run: The exchange to run.
  ///   - failure: How an error `run` throws reads as a `TransportError`.
  package func start(
    _ run: @escaping @Sendable () async throws -> Void,
    failure: @escaping @Sendable (any Error) -> TransportError
  ) {
    let task = Task {
      defer { control.detach() }
      do {
        try await run()
        let unanswered = TransportError.transport(kind: .other, underlying: nil)
        if settle(.failure(unanswered)) {
          buffer.finish(throwing: unanswered)
        }
      } catch {
        let failure = failure(error)
        settle(.failure(failure))
        buffer.finish(throwing: failure)
      }
    }
    control.attach(task)
  }

  /// Settles the response with `head`, then reads `body` into the buffer to its end.
  ///
  /// Each buffer the client delivers is appended as one chunk. Before every pull the task waits
  /// while the buffer holds its control suspended, so a reader that has fallen behind pauses the
  /// connection rather than filling memory. A clean end finishes the buffer with `nil`; a failure
  /// the body throws propagates to ``start(_:failure:)``, which finishes the buffer with it.
  ///
  /// - Parameters:
  ///   - head: The status and header fields.
  ///   - body: The client's body, read once, here.
  /// - Throws: The error the body's iterator throws, unchanged.
  package func deliver(head: Head, body: HTTPClientResponse.Body) async throws {
    settle(.success(head))
    var iterator = body.makeAsyncIterator()
    while true {
      await control.waitWhileSuspended()
      guard let chunk = try await iterator.next() else { break }
      buffer.append(Data(buffer: chunk))
    }
    buffer.finish(throwing: nil)
  }

  /// The body, as the one `StreamedBody` the buffer hands out.
  ///
  /// Releasing the body and every iterator over it cancels the buffer, which cancels the task
  /// through the exchange's control.
  ///
  /// - Returns: The chunks, in the order the client delivered them.
  package func makeBody() -> StreamedBody {
    buffer.makeBody()
  }

  /// The response, parking until the task delivers one or fails first.
  ///
  /// Called once per exchange. The answer is kept, so a response that arrived before the call is
  /// returned at once. The exchange parks one caller: a second call arriving while one is parked
  /// is a programming error and traps.
  ///
  /// - Returns: The status and header fields as received.
  /// - Throws: The `TransportError` the request failed with before any response arrived.
  package func response() async throws(TransportError) -> Head {
    let answer = await withCheckedContinuation { (continuation: Waiter) in
      let settled: Answer? = state.withLock { state in
        if let answer = state.answer {
          return answer
        }
        // A second caller parked here would overwrite the first and strand it; this reports the
        // misuse, it does not resolve it.
        precondition(state.waiter == nil, "StreamingExchange answers one caller at a time")
        state.waiter = continuation
        return nil
      }
      if let settled {
        continuation.resume(returning: settled)
      }
    }
    return try answer.get()
  }

  /// Cancels the task, so a request still in flight is cancelled and a body still arriving ends.
  ///
  /// A caller cancelled while parked on ``response()`` calls this, and the task's cancellation
  /// comes back through the exchange as the response's failure.
  package func cancel() {
    control.cancel()
  }

  /// Settles the response once: the first answer is kept and wakes a parked caller, and every
  /// later one is ignored.
  ///
  /// - Returns: Whether `answer` is the one kept.
  @discardableResult
  private func settle(_ answer: Answer) -> Bool {
    let (kept, waiter): (Bool, Waiter?) = state.withLock { state in
      guard state.answer == nil else { return (false, nil) }
      state.answer = answer
      return (true, state.waiter.take())
    }
    waiter?.resume(returning: answer)
    return kept
  }
}

/// The task reading a response body as the `FlowControl` its buffer pauses, restarts, and stops.
///
/// The task pulls one buffer at a time from the client, and waits on ``waitWhileSuspended()``
/// before each pull. ``suspend()`` makes the next such wait park; ``resume()`` lets it through and
/// wakes a task already parked; ``cancel()`` cancels the task and wakes it if parked, so a task
/// waiting on the client sees the cancellation there and one waiting here leaves at once. The task
/// is held from ``attach(_:)`` until it ends and calls ``detach()``, which is what keeps the buffer,
/// the control, and the task from holding one another past the body's end: the task holds the
/// exchange, the exchange holds the buffer, and the buffer holds this control. A task attached
/// after ``cancel()`` is cancelled on the spot rather than held, so no task is ever stored that
/// nothing will cancel.
///
/// ```swift
/// let control = PumpControl()
/// let buffer = ChunkBuffer(control: control)
/// ```
///
/// All three `FlowControl` calls arrive inside the buffer's critical section. Each returns after
/// updating the control's own state and, at most, resuming a parked continuation or cancelling the
/// task, neither of which reaches back into the buffer.
package final class PumpControl: FlowControl, Sendable {
  private struct State {
    var cancelled = false
    var finished = false
    var suspended = false
    var task: Task<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
  }

  private let state = Mutex(State())

  /// Creates a control with no task attached and delivery running.
  package init() {}

  /// Holds `task` until ``detach()``; drops it at once when the task has already detached, and
  /// cancels it at once when ``cancel()`` has already been called.
  ///
  /// - Parameter task: The task reading the body.
  package func attach(_ task: Task<Void, Never>) {
    let cancelNow: Bool = state.withLock { state in
      guard !state.finished else { return state.cancelled }
      state.task = task
      return false
    }
    if cancelNow {
      task.cancel()
    }
  }

  /// Releases the task, called by the task itself as its last act.
  package func detach() {
    state.withLock { state in
      state.finished = true
      state.task = nil
    }
  }

  /// Returns once delivery is running: at once while it is, and after ``resume()`` or
  /// ``cancel()`` while it is suspended.
  ///
  /// One task waits here at a time; a second would overwrite the first's continuation and strand
  /// it, so it traps.
  package func waitWhileSuspended() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let parked: Bool = state.withLock { state in
        guard state.suspended else { return false }
        precondition(state.waiter == nil, "PumpControl parks one task at a time")
        state.waiter = continuation
        return true
      }
      if !parked {
        continuation.resume()
      }
    }
  }

  /// Cancels the task and wakes it if it is parked here, so it leaves whichever wait it is in.
  ///
  /// The control is finished from here on: a task attached afterwards is cancelled at once.
  package func cancel() {
    let (task, waiter) = state.withLock { state in
      state.cancelled = true
      state.finished = true
      state.suspended = false
      return (state.task.take(), state.waiter.take())
    }
    task?.cancel()
    waiter?.resume()
  }

  /// Lets the next pull through, waking a task parked on ``waitWhileSuspended()``.
  package func resume() {
    let waiter = state.withLock { state in
      state.suspended = false
      return state.waiter.take()
    }
    waiter?.resume()
  }

  /// Parks the task at its next ``waitWhileSuspended()`` until ``resume()``.
  package func suspend() {
    state.withLock { $0.suspended = true }
  }
}

#endif
