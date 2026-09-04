// The test types here serve suites that exist only behind the `HTTPPortable` trait, so they
// compile only where those do.
#if HTTPPortable

import Synchronization

/// A counter tasks arrive at synchronously while others await it, so a test can hold work open
/// until a fixed number of tasks have reached the same point. Waiters are released inside the same
/// critical section that counts the arrival, so a resume is never left owing. No waiter here is
/// cancellation-aware.
final class Latch: Sendable {
  private struct State {
    var arrivals = 0
    var waiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
  }

  private let state = Mutex(State())

  func arrive() {
    let due = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.arrivals += 1
      let ready = state.waiters.filter { $0.threshold <= state.arrivals }
      state.waiters.removeAll { $0.threshold <= state.arrivals }
      return ready.map(\.continuation)
    }
    for continuation in due {
      continuation.resume()
    }
  }

  func wait(forCount count: Int) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumeNow = state.withLock { state -> Bool in
        guard state.arrivals < count else { return true }
        state.waiters.append((threshold: count, continuation: continuation))
        return false
      }
      if resumeNow {
        continuation.resume()
      }
    }
  }
}

#endif
