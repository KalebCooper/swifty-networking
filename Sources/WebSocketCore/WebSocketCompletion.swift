import Synchronization

/// A shared result whose observers can leave independently of the operation.
package final class WebSocketCompletion<Value: Sendable>: Sendable {
  private typealias Waiter = CheckedContinuation<Result<Value, WebSocketError>, Never>

  private struct State {
    var result: Result<Value, WebSocketError>?
    var waiters: [ObjectIdentifier: Waiter] = [:]
  }

  private final class Ticket: Sendable {}

  private let state = Mutex(State())

  package init() {}

  package func finish(_ result: Result<Value, WebSocketError>) {
    let waiters = state.withLock { state -> [Waiter] in
      guard state.result == nil else { return [] }
      state.result = result
      let waiters = Array(state.waiters.values)
      state.waiters.removeAll()
      return waiters
    }
    for waiter in waiters { waiter.resume(returning: result) }
  }

  package func wait() async throws(WebSocketError) -> Value {
    let ticket = Ticket()
    let id = ObjectIdentifier(ticket)
    let result: Result<Value, WebSocketError> = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediate = state.withLock { state -> Result<Value, WebSocketError>? in
          if Task.isCancelled { return .failure(WebSocketError(kind: .cancelled)) }
          if let result = state.result { return result }
          state.waiters[id] = continuation
          return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
      }
    } onCancel: {
      // Keep the identity alive until a possibly delayed cancellation handler has returned.
      let waiter = self.state.withLock { $0.waiters.removeValue(forKey: ObjectIdentifier(ticket)) }
      waiter?.resume(returning: .failure(WebSocketError(kind: .cancelled)))
    }
    guard !Task.isCancelled else { throw WebSocketError(kind: .cancelled) }
    return try result.get()
  }
}
