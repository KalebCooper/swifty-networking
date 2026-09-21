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
public final class ScriptedWebSocketConnection: Sendable {
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

  private let script: WebSocketScript<Operation, Outcome>

  /// Creates a connection script with no implicit successful operations.
  public init(steps: [Step] = []) {
    script = WebSocketScript(answers: steps.map { .init(gate: $0.gate, result: $0.result) })
  }

  /// All recorded operations, including calls made after the script was exhausted.
  public var operations: [Operation] { script.calls }

  /// Records an operation and returns the next seeded outcome.
  ///
  /// Operation names do not select outcomes. The test supplies the entire script.
  public func perform(_ operation: Operation) async throws(WebSocketError) -> Outcome {
    try await script.perform(operation)
  }
}
