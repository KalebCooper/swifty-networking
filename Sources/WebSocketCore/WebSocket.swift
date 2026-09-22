#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// An explicitly owned connection with one recoverable message reader.
///
/// The handle, messages value and iterators keep the connection alive. Releasing the last of
/// these owners aborts it. Internal receive and timer tasks do not extend external ownership.
public final class WebSocket: Sendable {
  private let owner: WebSocketOwner

  init(session: WebSocketSession) {
    owner = WebSocketOwner(session: session)
    session.start()
  }

  /// Creates the shared session for an already accepted server connection.
  package static func accepted(
    _ connection: any WebSocketConnection, options: Options
  ) throws(WebSocketError) -> WebSocket {
    try options.validate()
    return WebSocket(
      session: WebSocketSession(
        backend: connection, clock: WebSocketClock(ContinuousClock()), options: options))
  }

  /// Backend-reported closure metadata; it does not prove peer acknowledgement.
  public var closeInfo: WebSocketClose? { owner.session.closeInfo }
  /// A lazy reader view of the connection's existing receive pump.
  public var messages: WebSocketMessages { WebSocketMessages(owner: owner) }
  /// The protocol negotiated during the upgrade.
  public var negotiatedSubprotocol: String? { owner.session.negotiatedSubprotocol }

  /// Aborts this connection and releases pending operations. Repeated calls have no effect.
  public func cancel() { owner.session.cancel() }

  /// Finishes the active write, rejects queued sends, and awaits backend close completion.
  ///
  /// The first valid code and reason win; repeated calls join that close and its original
  /// closeTimeout, including time spent waiting for the active write. Invalid input has no effect.
  /// A reason may occupy at most 123 UTF-8 bytes. Reserved wire codes throw invalidRequest.
  /// Cancellation before admission starts nothing. After admission, cancellation follows the
  /// caller's policy. A deadline or backend failure aborts the connection.
  /// Success reports backend completion, not verified peer acknowledgement. Returned metadata
  /// may describe the locally requested close.
  @discardableResult
  public func close(
    cancellation: CloseCancellationPolicy = .stopWaiting,
    code: CloseCode = .normalClosure,
    reason: String? = nil
  ) async throws(WebSocketError) -> WebSocketClose {
    try await owner.session.close(cancellation: cancellation, code: code, reason: reason)
  }

  /// Synchronously admits binary data and returns its shared completion.
  public func enqueue(
    _ data: Data, failurePolicy: SendFailurePolicy? = nil, policy: SendPolicy? = nil
  ) throws(WebSocketError) -> SendOperation {
    try enqueue(.binary(data), failurePolicy: failurePolicy, policy: policy)
  }

  /// Synchronously admits text, counting its UTF-8 bytes against send capacity.
  public func enqueue(
    _ text: String, failurePolicy: SendFailurePolicy? = nil, policy: SendPolicy? = nil
  ) throws(WebSocketError) -> SendOperation {
    try enqueue(.text(text), failurePolicy: failurePolicy, policy: policy)
  }

  /// Synchronously validates and admits a message into the connection's bounded FIFO.
  ///
  /// Sequential calls establish admission order. Concurrent callers are ordered at admission.
  /// Defaults are captured at connect; overrides affect only this message. Rejection throws
  /// concurrentOperation for overlapping rejection-policy sends or sendQueueFull for capacity.
  /// Oversized messages throw messageTooLarge. Pre-cancellation throws cancelled.
  /// These failures follow failurePolicy; an already closing connection simply throws closed.
  /// This method never waits for capacity or network I/O.
  public func enqueue(
    _ message: Message, failurePolicy: SendFailurePolicy? = nil, policy: SendPolicy? = nil
  ) throws(WebSocketError) -> SendOperation {
    try owner.session.enqueue(message, failurePolicy: failurePolicy, policy: policy)
  }

  /// Sends one ping and waits for its pong within the captured pingTimeout.
  ///
  /// Overlap throws concurrentOperation. Cancellation before admission sends nothing; after
  /// admission it releases only this caller. The physical probe keeps its original deadline.
  /// Missing that deadline terminates the connection with timedOut, even after caller cancellation.
  public func ping() async throws(WebSocketError) { try await owner.session.ping() }

  /// Sends binary data using the same admission and failure policies as enqueue.
  public func send(
    _ data: Data, failurePolicy: SendFailurePolicy? = nil, policy: SendPolicy? = nil
  ) async throws(WebSocketError) {
    try await send(.binary(data), failurePolicy: failurePolicy, policy: policy)
  }

  /// Sends text using the same admission and failure policies as enqueue.
  public func send(
    _ text: String, failurePolicy: SendFailurePolicy? = nil, policy: SendPolicy? = nil
  ) async throws(WebSocketError) {
    try await send(.text(text), failurePolicy: failurePolicy, policy: policy)
  }

  /// Admits a message and waits for its backend write within the captured sendTimeout.
  ///
  /// One deadline includes admission, queue residence and writing. Cancellation cancels this
  /// send: queued work follows failurePolicy; active-write failure always aborts the connection.
  /// Success is backend write completion, not application acknowledgement. Failure does not
  /// establish that the peer received nothing.
  public func send(
    _ message: Message, failurePolicy: SendFailurePolicy? = nil, policy: SendPolicy? = nil
  ) async throws(WebSocketError) {
    let operation = try enqueue(message, failurePolicy: failurePolicy, policy: policy)
    let result: Result<Void, WebSocketError> = await withTaskCancellationHandler {
      do throws(WebSocketError) {
        try await operation.wait()
        return .success(())
      } catch {
        return .failure(error)
      }
    } onCancel: {
      operation.cancel()
    }
    guard !Task.isCancelled else { throw WebSocketError(kind: .cancelled) }
    try result.get()
  }
}

/// Only consumer-facing values retain this token; pump and timer tasks retain the session directly.
final class WebSocketOwner: Sendable {
  let session: WebSocketSession

  init(session: WebSocketSession) { self.session = session }

  deinit { session.cancel() }
}
