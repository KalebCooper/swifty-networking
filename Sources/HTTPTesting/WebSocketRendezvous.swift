import Synchronization
import WebSocketCore

/// A manually released gate for scripted WebSocket operations.
///
/// Await an arrival before inspecting or releasing a parked operation. Cancellation removes
/// only the cancelled test waiter; it does not prescribe live WebSocket cancellation behavior.
public final class WebSocketRendezvous: Sendable {
  private struct State {
    var arrivals = 0
    var isReleased = false
    var nextID = 0
    var waiters: [Int: Waiter] = [:]
  }

  private struct Waiter {
    let continuation: CheckedContinuation<Result<Void, WebSocketError>, Never>
    let threshold: Int?
  }

  private let state = Mutex(State())

  /// Creates an unreleased gate.
  public init() {}

  /// The number of operations that have reached this gate.
  public var arrivals: Int { state.withLock { $0.arrivals } }

  /// The number of suspended operation and arrival waiters.
  public var pendingWaiters: Int { state.withLock { $0.waiters.count } }

  /// Records an arrival and releases arrival observers without suspending.
  public func arrive() {
    let ready = state.withLock { state in
      state.arrivals += 1
      let ready = state.waiters.filter { _, waiter in
        waiter.threshold.map { state.arrivals >= $0 } ?? false
      }
      for id in ready.keys { state.waiters.removeValue(forKey: id) }
      return Array(ready.values)
    }
    for waiter in ready { waiter.continuation.resume(returning: .success(())) }
  }

  /// Records an arrival and suspends until release or cancellation.
  public func arriveAndWait() async throws(WebSocketError) {
    arrive()
    try await wait(threshold: nil)
  }

  /// Releases current and future operations without inventing an outcome.
  public func release() {
    let ready = state.withLock { state in
      state.isReleased = true
      let ready = state.waiters.filter { $0.value.threshold == nil }
      for id in ready.keys { state.waiters.removeValue(forKey: id) }
      return Array(ready.values)
    }
    for waiter in ready { waiter.continuation.resume(returning: .success(())) }
  }

  /// Suspends until the given number of operations have arrived.
  ///
  /// Cancellation throws a cancelled error even when the requested count has not arrived.
  public func waitForArrival(count: Int = 1) async throws(WebSocketError) {
    try await wait(threshold: count)
  }

  private func wait(threshold: Int?) async throws(WebSocketError) {
    let id = state.withLock { state in
      let id = state.nextID
      state.nextID += 1
      return id
    }
    let result: Result<Void, WebSocketError> = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediate: Result<Void, WebSocketError>? = state.withLock { state in
          if Task.isCancelled { return .failure(WebSocketError(kind: .cancelled)) }
          if threshold.map({ state.arrivals >= $0 }) ?? state.isReleased { return .success(()) }
          state.waiters[id] = Waiter(continuation: continuation, threshold: threshold)
          return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
      }
    } onCancel: {
      let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
      waiter?.continuation.resume(returning: .failure(WebSocketError(kind: .cancelled)))
    }
    try result.get()
  }
}
