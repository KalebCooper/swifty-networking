// `URLSession` and the loading system behind it exist only on Apple platforms, so this target
// compiles only where they do.
#if canImport(Darwin)

import Foundation
import HTTPCore
import HTTPTypes
import HTTPTypesFoundation
import Synchronization

/// The delegate of one `URLSessionDataTask`, handing its response to the caller awaiting it and its
/// chunks to a `ChunkBuffer` as the loading system delivers them.
///
/// ``URLSessionTransport/stream(_:body:options:)`` gives every task a delegate of its own: the task holds
/// it, and it holds the buffer the body is read from. The response is answered once, through
/// ``response()``, from whichever callback settles it first: `didReceive response` with the status
/// and header fields, or `didCompleteWithError` with the mapped failure when the request produced
/// no response at all. Every `didReceive data` after that appends one chunk, and the completion
/// finishes the buffer with `nil` or the failure that ended the body, so a failure after the
/// response reaches the reader through the body and never through the call.
///
/// ```swift
/// let task = session.dataTask(with: urlRequest)
/// let delegate = StreamingTaskDelegate(control: TaskControl(task: task))
/// task.delegate = delegate
/// task.resume()
///
/// let response = try await delegate.response()
/// for try await chunk in delegate.makeBody() {
///   handle(chunk)
/// }
/// ```
///
/// The buffer's flow control is whatever `control` was given: the transport passes a box holding
/// the task weakly, so the buffer suspends and resumes the task itself and cancels it when the body
/// is dropped, and the buffer never keeps the task alive. The loading system calls back on its own
/// thread, serially per task, and every callback here is settled under one `Mutex` or handed
/// straight to the buffer, so the delegate needs no queue of its own.
///
/// A task whose body is a file keeps the file's URL here, so when the loading system asks for the
/// body again, as it does to answer an authentication challenge, the delegate opens a fresh stream
/// on the same file instead of failing the task.
///
/// A redirect is refused, as ``RedirectRefusingDelegate`` refuses one on the buffered path, so the
/// `3xx` itself is the response that settles ``response()`` and no hop is walked behind the
/// client's ``/HTTPCore/HTTPClient/redirectPolicy``.
package final class StreamingTaskDelegate: NSObject, URLSessionDataDelegate, Sendable {
  /// What the caller awaiting the response receives: the status and header fields, or the failure
  /// that stood in for them.
  private typealias Answer = Result<HTTPResponse, TransportError>

  /// A caller parked on ``response()``.
  private typealias Waiter = CheckedContinuation<Answer, Never>

  private struct State {
    var answer: Answer?
    var waiter: Waiter?
  }

  private let bodyFile: URL?
  private let buffer: ChunkBuffer
  private let state = Mutex(State())

  /// Creates a delegate whose buffer pauses, restarts, and stops the producer through `control`.
  ///
  /// - Parameters:
  ///   - bodyFile: The file the request body is streamed from, or `nil` for a body that is not a
  ///     file; defaults to `nil`.
  ///   - control: What the buffer suspends when it is ahead of the reader by more than its high
  ///     watermark, resumes when the reader catches up, and cancels when the reader goes away.
  package init(bodyFile: URL? = nil, control: any FlowControl) {
    self.bodyFile = bodyFile
    buffer = ChunkBuffer(control: control)
  }

  /// The body, as the one `StreamedBody` the buffer hands out.
  ///
  /// Releasing the body and every iterator over it cancels the buffer, which cancels the producer
  /// through the delegate's `control`.
  ///
  /// - Returns: The chunks, in the order the loading system delivered them.
  package func makeBody() -> StreamedBody {
    buffer.makeBody()
  }

  /// The response, parking until the loading system delivers one or fails the task first.
  ///
  /// Called once per task. The answer is kept, so a response that arrived before the call is
  /// returned at once. The delegate parks one caller: a second call arriving while one is parked
  /// is a programming error and traps.
  ///
  /// - Returns: The status and header fields as received.
  /// - Throws: The `TransportError` the request failed with before any response arrived, or the
  ///   failure that stands in for a response the transport cannot read as HTTP.
  package func response() async throws(TransportError) -> HTTPResponse {
    let answer = await withCheckedContinuation { (continuation: Waiter) in
      let settled: Answer? = state.withLock { state in
        if let answer = state.answer {
          return answer
        }
        // A second caller parked here would overwrite the first and strand it; this reports the
        // misuse, it does not resolve it.
        precondition(state.waiter == nil, "StreamingTaskDelegate answers one caller at a time")
        state.waiter = continuation
        return nil
      }
      if let settled {
        continuation.resume(returning: settled)
      }
    }
    return try answer.get()
  }

  /// Settles the response once: the first answer is kept and wakes a parked caller, and every
  /// later one is ignored.
  private func settle(_ answer: Answer) {
    let waiter: Waiter? = state.withLock { state in
      guard state.answer == nil else { return nil }
      state.answer = answer
      return state.waiter.take()
    }
    waiter?.resume(returning: answer)
  }

  /// Settles the response with the status and header fields, or with the failure that names what
  /// arrived instead, in which case the task is cancelled: there is no HTTP response to stream a
  /// body for.
  package func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    // URLSession reports both of the answers below as successes, so the error that says what
    // arrived instead is this transport's to supply.
    guard let httpURLResponse = response as? HTTPURLResponse else {
      settle(
        .failure(
          .transport(
            kind: .other,
            underlying: URLSessionResponseFailure.notHTTP(
              responseType: String(describing: type(of: response)), url: response.url))))
      completionHandler(.cancel)
      return
    }
    guard let httpResponse = httpURLResponse.httpResponse else {
      settle(
        .failure(
          .transport(
            kind: .other,
            underlying: URLSessionResponseFailure.unrepresentableStatus(
              code: httpURLResponse.statusCode, url: httpURLResponse.url))))
      completionHandler(.cancel)
      return
    }
    settle(.success(httpResponse))
    completionHandler(.allow)
  }

  /// Refuses the redirect, so the `3xx` is delivered through `didReceive response` as the task's
  /// response, with its body, and settles the response as any other status does.
  package func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  /// Hands the loading system a fresh stream on the body file, or `nil` for a body that is not a
  /// file, which the loading system replays from the request itself.
  package func urlSession(
    _ session: URLSession, task: URLSessionTask,
    needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
  ) {
    completionHandler(bodyFile.flatMap { InputStream(url: $0) })
  }

  /// Appends one chunk, exactly as the loading system delivered it.
  package func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
  ) {
    buffer.append(data)
  }

  /// Ends the body with `nil` or the mapped failure, and fails the response when none arrived.
  ///
  /// The failure is offered to the response first: it settles the response only when no response
  /// was delivered, and is otherwise the body's ending. A task that finishes with no error and no
  /// response, which no network loader produces but a `URLProtocol` can, is reported as a failure
  /// with nothing behind it rather than leaving the caller parked.
  package func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let failure = error.map(URLSessionTransport.failure(from:))
    settle(.failure(failure ?? .transport(kind: .other, underlying: nil)))
    buffer.finish(throwing: failure)
  }
}

/// A `URLSessionDataTask` as the `FlowControl` its buffer pauses, restarts, and stops.
///
/// The task is held weakly. The buffer holds its control strongly and the task holds the delegate
/// that holds the buffer, so a strong reference here would keep the task alive for as long as the
/// task itself kept its delegate. A task that has completed and gone away answers every call with
/// nothing, and `resume()` on a completed task still in memory is harmless.
///
/// ```swift
/// let buffer = ChunkBuffer(control: TaskControl(task: task))
/// ```
package struct TaskControl: FlowControl {
  /// The task, for as long as its session holds it.
  private weak var task: URLSessionDataTask?

  /// Creates a control over `task`.
  ///
  /// - Parameter task: The task the buffer is fed from.
  package init(task: URLSessionDataTask) {
    self.task = task
  }

  /// Cancels the task, which completes it with `URLError.cancelled`.
  ///
  /// `URLSessionTask.cancel()` returns without calling back on the caller's thread, the completion
  /// arriving later on the loading system's, which is why the buffer can call this inside its
  /// `Mutex`.
  package func cancel() {
    task?.cancel()
  }

  /// Resumes the task after ``suspend()``.
  package func resume() {
    task?.resume()
  }

  /// Suspends the task, so no further chunk is delivered until ``resume()``.
  package func suspend() {
    task?.suspend()
  }
}

#endif
