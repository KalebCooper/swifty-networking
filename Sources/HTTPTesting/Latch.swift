import Synchronization

/// A counter tasks arrive at synchronously while others await it.
///
/// A test holds work open until a fixed number of tasks have reached the same point: each task
/// calls `arrive()`, and the test awaits `wait(forCount:)`. Waiters whose count is reached are
/// taken in the same critical section that counts the arrival and resumed after it, so a resume is
/// never left owing.
///
/// A waiter is cancellation-aware. Cancelling the waiting task throws `CancellationError` at once,
/// even when the count has not arrived, so a suite time limit ends a test parked on an arrival
/// that never comes.
///
/// ```swift
/// let latch = Latch()
/// let worker = Task {
///   latch.arrive()
/// }
/// try await latch.wait(forCount: 1)
/// await worker.value
/// ```
package final class Latch: Sendable {
  private struct State {
    var arrivals = 0
    var nextID = 0
    var waiters: [Int: Waiter] = [:]
  }

  private struct Waiter {
    let continuation: CheckedContinuation<Result<Void, CancellationError>, Never>
    let threshold: Int
  }

  private let state = Mutex(State())

  /// Creates a latch no task has arrived at.
  package init() {}

  /// Records an arrival and resumes every waiter whose count it reaches, without suspending.
  package func arrive() {
    let ready = state.withLock { state in
      state.arrivals += 1
      let ready = state.waiters.filter { _, waiter in waiter.threshold <= state.arrivals }
      for id in ready.keys { state.waiters.removeValue(forKey: id) }
      return Array(ready.values)
    }
    for waiter in ready { waiter.continuation.resume(returning: .success(())) }
  }

  /// Suspends until the given number of arrivals have been recorded.
  ///
  /// Returns at once when the count has already arrived.
  ///
  /// - Parameter count: The number of arrivals to wait for.
  /// - Throws: `CancellationError` when the waiting task is cancelled, whether it was cancelled
  ///   before the call or while suspended.
  package func wait(forCount count: Int) async throws(CancellationError) {
    let id = state.withLock { state in
      let id = state.nextID
      state.nextID += 1
      return id
    }
    let result: Result<Void, CancellationError> = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediate: Result<Void, CancellationError>? = state.withLock { state in
          if Task.isCancelled { return .failure(CancellationError()) }
          if state.arrivals >= count { return .success(()) }
          state.waiters[id] = Waiter(continuation: continuation, threshold: count)
          return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
      }
    } onCancel: {
      let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
      waiter?.continuation.resume(returning: .failure(CancellationError()))
    }
    try result.get()
  }
}
