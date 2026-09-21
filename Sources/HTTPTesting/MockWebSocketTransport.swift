import WebSocketCore

/// Records connection inputs and returns scripted connections or errors.
///
/// This test type performs no network, credential, validation or retry work. It does not
/// conform to a live transport protocol. Every call consumes exactly one answer.
public final class MockWebSocketTransport: Sendable {
  /// One explicit connection outcome.
  public struct Answer: Sendable {
    /// A gate reached after recording the call and consuming this answer.
    public let gate: WebSocketRendezvous?
    /// The connection or error supplied by the test.
    public let result: Result<ScriptedWebSocketConnection, WebSocketError>

    /// Creates an answer with an optional operation gate.
    public init(
      gate: WebSocketRendezvous? = nil,
      result: Result<ScriptedWebSocketConnection, WebSocketError>
    ) {
      self.gate = gate
      self.result = result
    }
  }

  /// The unmodified inputs of a recorded connection call.
  public struct Call: Sendable {
    /// The supplied send configuration.
    public let options: WebSocket.Options
    /// The supplied outbound request, including its original authentication value.
    public let request: WebSocketRequest

    /// Creates a call record.
    public init(options: WebSocket.Options, request: WebSocketRequest) {
      self.options = options
      self.request = request
    }
  }

  private let script: WebSocketScript<Call, ScriptedWebSocketConnection>

  /// Creates a transport with explicitly seeded connection answers.
  public init(answers: [Answer] = []) {
    script = WebSocketScript(answers: answers.map { .init(gate: $0.gate, result: $0.result) })
  }

  /// Every connection call in admission order, including unanswered calls.
  public var calls: [Call] { script.calls }

  /// Records the supplied inputs and returns the next seeded answer.
  ///
  /// Exhaustion throws a transport error carrying
  /// ``WebSocketScriptFailure/noScriptedOutcome``.
  public func connect(
    _ request: WebSocketRequest,
    options: WebSocket.Options = .init()
  ) async throws(WebSocketError) -> ScriptedWebSocketConnection {
    try await script.perform(Call(options: options, request: request))
  }
}
