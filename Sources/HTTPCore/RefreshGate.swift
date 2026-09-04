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
/// - A refresh is in flight: the caller joins it and awaits that task's result.
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
/// The refresh runs as an unstructured task that no waiter's cancellation reaches. A cancelled
/// joiner stops waiting, and `Task.value` is not cancellation-sensitive; a leader whose own request
/// is cancelled leaves the refresh running to completion. Under refresh-token rotation, a refresh
/// abandoned halfway loses the credential for every request, not only the cancelled one, so the
/// refresh finishes for everyone and cancellation is honoured by whoever drives the request
/// afterwards. Do not restructure this into a child task.
///
/// A failed refresh throws the refresher's own error to every waiter and, by the refresher's
/// contract, leaves the provider untouched.
final class RefreshGate: Sendable {
  /// The refresh in flight, or `nil` when none is; set and cleared under the lock only.
  ///
  /// The outcome travels as a `Result` in a never-failing task, because `Task` is only creatable
  /// with an untyped failure. The `Result` keeps the refresher's error typed all the way to every
  /// waiter.
  private let inFlight = Mutex<Task<Result<Void, TransportError>, Never>?>(nil)

  init() {}

  /// Refreshes through `refresher` unless the provider no longer holds `observed`, sharing a
  /// refresh already in flight with everyone waiting on it.
  ///
  /// - Parameters:
  ///   - observed: The token the caller sent or found expiring; `nil` when it sent none.
  ///   - provider: The provider the refresher installs into and the caller will re-read.
  ///   - refresher: What obtains the new credential.
  /// - Throws: The refresher's ``TransportError``, whether this caller led the refresh or joined
  ///   it.
  func refresh(
    replacing observed: String?,
    of provider: any TokenProvider,
    with refresher: any TokenRefresher
  ) async throws(TransportError) {
    let shared: Task<Result<Void, TransportError>, Never>? = inFlight.withLock { slot in
      if let slot { return slot }
      guard provider.currentToken() == observed else { return nil }
      let task = Task<Result<Void, TransportError>, Never> {
        defer { self.inFlight.withLock { $0 = nil } }
        do throws(TransportError) {
          try await refresher.refresh()
          return .success(())
        } catch {
          return .failure(error)
        }
      }
      slot = task
      return task
    }
    guard let shared else { return }
    try await shared.value.get()
  }
}
