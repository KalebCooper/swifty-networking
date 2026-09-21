import WebSocketCore

/// Records operations and replays explicitly seeded outcomes in call-admission order.
///
/// This is test support, not a live connection or a lifecycle implementation. A close, cancellation
/// or failure has no effect on later steps unless the test supplies that outcome. No authentication,
/// retries, admission limits, timeout or receive policy is inferred.
///
/// Each call consumes one step, including a call cancelled while waiting at its step's gate.
/// An exhausted script throws a transport error carrying
/// ``WebSocketScriptFailure/noScriptedOutcome``.
public final class ScriptedWebSocketConnection: WebSocketConnection {
  /// One operation as supplied by the test or code under test.
  public enum Operation: Equatable, Sendable {
    /// A connection-abort request.
    case cancel
    /// A close request with its exact arguments.
    case close(code: WebSocket.CloseCode, reason: String?)
    /// A ping request.
    case ping
    /// A receive request.
    case receive
    /// A send request with its complete message.
    case send(WebSocket.Message)
  }

  /// An outcome supplied by the test without inferred connection behavior.
  public enum Outcome: Equatable, Sendable {
    /// Close metadata, without asserting a completed handshake.
    case close(WebSocketClose)
    /// Completion of an operation without a returned value.
    case completed
    /// A received message, or a scripted end.
    case message(WebSocket.Message?)
  }

  /// A result and optional rendezvous for one recorded operation.
  public struct Step: Sendable {
    /// A gate reached after recording the operation and consuming this step.
    public let gate: WebSocketRendezvous?
    /// The exact outcome to return after the gate is released.
    public let result: Result<Outcome, WebSocketError>

    /// Creates a step with an explicit success or failure.
    public init(gate: WebSocketRendezvous? = nil, result: Result<Outcome, WebSocketError>) {
      self.gate = gate
      self.result = result
    }
  }

  /// Explicitly seeded peer close metadata, independent of scripted outcomes.
  public let closeInfo: WebSocketClose?
  /// Explicitly seeded negotiated subprotocol.
  public let negotiatedSubprotocol: String?

  private let cancellation = WebSocketRendezvous()
  private let script: WebSocketScript<Operation, Outcome>

  /// Creates a connection script with no implicit successful operations.
  public init(
    closeInfo: WebSocketClose? = nil,
    negotiatedSubprotocol: String? = nil,
    steps: [Step] = []
  ) {
    self.closeInfo = closeInfo
    self.negotiatedSubprotocol = negotiatedSubprotocol
    script = WebSocketScript(answers: steps.map { .init(gate: $0.gate, result: $0.result) })
  }

  /// All recorded operations, including calls made after the script was exhausted.
  public var operations: [Operation] { script.calls }

  /// Records synchronous abort without consuming an asynchronous step.
  public func cancel() {
    script.record(.cancel)
    cancellation.release()
  }

  /// Records close and returns the explicitly seeded close outcome.
  public func close(code: WebSocket.CloseCode, reason: String?)
    async throws(WebSocketError) -> WebSocketClose
  {
    guard case .close(let close) = try await perform(.close(code: code, reason: reason)) else {
      throw mismatch()
    }
    return close
  }

  /// Records an operation and returns the next seeded outcome.
  ///
  /// Operation names do not select outcomes. The test supplies the entire script.
  public func perform(_ operation: Operation) async throws(WebSocketError) -> Outcome {
    try await script.perform(operation)
  }

  /// Records ping and requires an explicitly seeded completion.
  public func ping() async throws(WebSocketError) {
    guard case .completed = try await perform(.ping) else { throw mismatch() }
  }

  /// Records receive and returns the explicitly seeded message or end.
  public func receive() async throws(WebSocketError) -> WebSocket.Message? {
    guard case .message(let message) = try await perform(.receive) else { throw mismatch() }
    return message
  }

  /// Records send and requires an explicitly seeded completion.
  public func send(_ message: WebSocket.Message) async throws(WebSocketError) {
    guard case .completed = try await perform(.send(message)) else { throw mismatch() }
  }

  /// Waits until cancel has been recorded, or throws if this test waiter is cancelled.
  public func waitForCancellation() async throws(WebSocketError) {
    try await cancellation.arriveAndWait()
  }

  private func mismatch() -> WebSocketError {
    WebSocketError(kind: .transport, underlying: WebSocketScriptFailure.mismatchedOutcome)
  }
}
