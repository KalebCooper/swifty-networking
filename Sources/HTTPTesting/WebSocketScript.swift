import Synchronization
import WebSocketCore

/// Shared recording and atomic consumption for scripted outcomes.
final class WebSocketScript<Input: Sendable, Output: Sendable>: Sendable {
  struct Answer: Sendable {
    let gate: WebSocketRendezvous?
    let result: Result<Output, WebSocketError>
  }

  private struct State {
    var answers: [Answer]
    var calls: [Input] = []
  }

  private let state: Mutex<State>

  init(answers: [Answer]) {
    state = Mutex(State(answers: answers))
  }

  var calls: [Input] { state.withLock { $0.calls } }

  func perform(_ input: Input) async throws(WebSocketError) -> Output {
    let answer = state.withLock { state -> Answer? in
      state.calls.append(input)
      return state.answers.isEmpty ? nil : state.answers.removeFirst()
    }
    guard let answer else {
      throw WebSocketError(kind: .transport, underlying: WebSocketScriptFailure.noScriptedOutcome)
    }
    if let gate = answer.gate { try await gate.arriveAndWait() }
    return try answer.result.get()
  }
}
