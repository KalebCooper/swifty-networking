import Synchronization

/// Settles one connect await without joining cancellation-insensitive credential or backend work.
final class WebSocketConnectWait<Value: Sendable>: Sendable {
  private typealias Outcome = Result<Value, WebSocketError>
  private typealias Waiter = CheckedContinuation<Outcome, Never>

  private struct State {
    var outcome: Outcome?
    var tasks: [Task<Void, Never>] = []
    var waiter: Waiter?
  }

  private let discard: @Sendable (Value) -> Void
  private let state = Mutex(State())

  init(discard: @escaping @Sendable (Value) -> Void) {
    self.discard = discard
  }

  func check() throws(WebSocketError) {
    if Task.isCancelled { throw WebSocketError(kind: .cancelled) }
    if let outcome = state.withLock({ $0.outcome }) {
      switch outcome {
      case .failure(let error): throw error
      case .success: throw WebSocketError(kind: .cancelled)
      }
    }
  }

  func run<C: Clock>(
    clock: C,
    deadline: C.Instant,
    operation: @escaping @Sendable () async throws(WebSocketError) -> Value
  ) async throws(WebSocketError) -> Value where C.Duration == Duration {
    let outcome: Outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediate: Outcome? = state.withLock { state in
          if let outcome = state.outcome { return outcome }
          if Task.isCancelled {
            let outcome: Outcome = .failure(WebSocketError(kind: .cancelled))
            state.outcome = outcome
            return outcome
          }
          state.waiter = continuation
          return nil
        }
        if let immediate {
          continuation.resume(returning: immediate)
          return
        }
        attach(
          Task {
            do {
              try await clock.sleep(until: deadline, tolerance: nil)
              self.finish(.failure(WebSocketError(kind: .timedOut)))
            } catch {
              if !Task.isCancelled {
                self.finish(.failure(WebSocketError(kind: .transport, underlying: error)))
              }
            }
          })
        attach(
          Task {
            do throws(WebSocketError) {
              try self.check()
              let value = try await operation()
              self.finish(.success(value))
            } catch {
              self.finish(.failure(error))
            }
          })
      }
    } onCancel: {
      self.finish(.failure(WebSocketError(kind: .cancelled)))
    }
    if Task.isCancelled {
      if case .success(let value) = outcome { discard(value) }
      throw WebSocketError(kind: .cancelled)
    }
    return try outcome.get()
  }

  private func attach(_ task: Task<Void, Never>) {
    let completed = state.withLock { state in
      guard state.outcome == nil else { return true }
      state.tasks.append(task)
      return false
    }
    if completed { task.cancel() }
  }

  private func finish(_ outcome: Outcome) {
    let completion: (Waiter?, [Task<Void, Never>])? = state.withLock { state in
      guard state.outcome == nil else { return nil }
      state.outcome = outcome
      let completion = (state.waiter, state.tasks)
      state.waiter = nil
      state.tasks = []
      return completion
    }
    guard let completion else {
      if case .success(let value) = outcome { discard(value) }
      return
    }
    for task in completion.1 { task.cancel() }
    completion.0?.resume(returning: outcome)
  }
}
