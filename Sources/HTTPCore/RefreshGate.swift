import Synchronization

/// Admits one credential refresh at a time and lets every request that needs the same refresh share
/// it, so a burst of `401`s, or a burst of requests finding the same token about to expire,
/// produces exactly one call to the ``TokenRefresher``.
///
/// The gate is a reference ``Authentication`` holds. A `Sendable` struct cannot own a `Mutex`
/// without becoming noncopyable, and copies of one credential must share a single gate, or two
/// copies could refresh the same provider independently. The gate's identity is what tells one
/// credential from another, so a value made again over the same provider is a second credential.
///
/// ## Who Refreshes, Who Joins, Who Skips
///
/// A caller arrives with the token it observed: the one the server rejected, or the one it found
/// about to expire. One critical section decides its fate.
///
/// - A refresh is in flight: the caller registers for its result.
/// - No refresh is in flight and the provider already holds a different token: the caller skips.
///   Someone else finished a refresh between this caller's observation and now, and the new
///   credential is what it will send next.
/// - Otherwise the caller leads: it starts the refresh, and every later arrival joins it.
///
/// The leader clears its slot only after `refresh()` has returned, so an empty slot means whatever
/// the refresh installed is already visible through the provider. Reading `currentToken()` inside
/// the gate's own critical section is what makes "empty slot, same token" a reliable signal that
/// nobody refreshed. One consequence: a refresher that installs a token equal to the previous one
/// leaves a late `401` holder unable to tell that the refresh happened, so it leads a second
/// refresh. The token it sent really was rejected, and the extra refresh runs against a server that
/// reissued the same credential.
///
/// ## Cancellation
///
/// Each caller registers its own continuation. Cancellation removes and resumes only that caller;
/// the unstructured refresh still finishes even when every waiter has left. Abandoning a rotating
/// refresh token could lose the credential for all clients. Completion clears the flight only after
/// the provider has been updated, and resumes the remaining waiters outside the lock.
///
/// A failed refresh delivers the refresher's error to every remaining waiter and leaves the
/// provider untouched under the refresher's contract.
final class RefreshGate: Sendable {
  private typealias Outcome = Result<Void, TransportError>
  private typealias Waiter = CheckedContinuation<Outcome, Never>

  private enum Arrival {
    case cancelled
    case joins
    case leads
    case skips
  }

  /// An empty table is still a live refresh; only completion resets it to nil.
  private let inFlight = Mutex<[UInt64: Waiter]?>(nil)
  private let tickets = Atomic<UInt64>(0)

  init() {}

  /// Shares a refresh unless the provider has already replaced the observed credential.
  func refresh(
    replacing observed: String?,
    of provider: any TokenProvider,
    with refresher: any TokenRefresher
  ) async throws(TransportError) {
    let ticket = tickets.wrappingAdd(1, ordering: .relaxed).newValue
    let outcome: Outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: Waiter) in
        // Registration and the cancellation check share the handler's lock, so cancellation
        // cannot slip between checking the task and publishing its continuation.
        let arrival: Arrival = inFlight.withLock { slot in
          guard !Task.isCancelled else { return .cancelled }
          if slot != nil {
            slot?[ticket] = continuation
            return .joins
          }
          guard provider.currentToken() == observed else { return .skips }
          slot = [ticket: continuation]
          return .leads
        }
        switch arrival {
        case .cancelled:
          continuation.resume(returning: .failure(.cancelled))
        case .joins:
          break
        case .leads:
          // This task has no parent cancellation relationship and owns completion even if
          // cancellation removes the last waiter before the refresher starts.
          Task {
            let outcome: Outcome
            do throws(TransportError) {
              try await refresher.refresh()
              outcome = .success(())
            } catch {
              outcome = .failure(error)
            }
            self.finish(with: outcome)
          }
        case .skips:
          continuation.resume(returning: .success(()))
        }
      }
    } onCancel: {
      let waiter = inFlight.withLock { $0?.removeValue(forKey: ticket) }
      waiter?.resume(returning: .failure(.cancelled))
    }
    guard !Task.isCancelled else { throw .cancelled }
    try outcome.get()
  }

  private func finish(with outcome: Outcome) {
    let waiters = inFlight.withLock { slot in
      let waiters = slot ?? [:]
      slot = nil
      return waiters
    }
    for waiter in waiters.values { waiter.resume(returning: outcome) }
  }
}
