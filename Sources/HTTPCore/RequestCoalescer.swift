import Synchronization

/// Lets concurrent requests that share a ``RequestOptions/coalescingKey`` share one exchange with
/// the server, so a burst of identical idempotent reads produces exactly one send and gives every
/// caller the same ``Response``.
///
/// The coalescer is a reference the client holds, for the same reason ``RefreshGate`` is: a
/// `Sendable` struct cannot own a `Mutex` without becoming noncopyable, and copies of one client
/// must share a single map.
///
/// ## Who Leads, Who Joins
///
/// The first caller to arrive under an identity leads: it creates the identity's flight and starts
/// the exchange as an unstructured task. Every caller that arrives while the flight exists, the
/// leader included, joins it as a waiter, and the flight resumes all of them with one outcome when
/// the exchange completes, success or failure alike. Leading confers no other privilege, so
/// cancellation is the same for everyone.
///
/// A flight lives from the moment its first caller registers until its exchange completes, and it
/// is removed in the same critical section that takes its waiters, so a caller arriving after that
/// instant leads a fresh exchange. The map is keyed by a ``CoalescingIdentity``: the exact string
/// the caller supplied, and the credential the client will send under. Nothing else is derived
/// from the request, so when two differing requests share an identity, the first one's exchange is
/// what everyone receives.
///
/// ## Cancellation
///
/// A cancelled waiter stops waiting at once and throws ``TransportError/cancelled``; the exchange
/// runs to completion for everyone still waiting. Nothing counts the waiters, so a flight every
/// caller has left still finishes, so one send may be answered for nobody, and a late arrival joins
/// the live flight instead of starting another. A caller that is already cancelled when it arrives
/// neither leads nor joins.
///
/// Each waiter is a continuation in a registry, and whichever side removes its entry, the finishing
/// flight or the waiter's own cancellation handler, is the side that resumes it. ``RefreshGate``
/// uses a task in a slot instead, because a refresh is short and must never be abandoned, so its
/// waiters may sit on `Task.value`, which no cancellation reaches. A coalesced send can be long,
/// and a waiter must be able to leave it.
final class RequestCoalescer: Sendable {
  /// What a flight delivers to every waiter: the exchange's response, or the error it threw.
  ///
  /// The error travels typed inside a `Result`, because the exchange runs in a `Task`, which is
  /// only creatable with an untyped failure.
  typealias Outcome = Result<Response, TransportError>

  /// A parked caller; resumed with `nil` when it was cancelled instead of answered.
  private typealias Waiter = CheckedContinuation<Outcome?, Never>

  /// What the registering critical section decided for an arriving caller.
  private enum Arrival {
    case cancelled
    case joins
    case leads
  }

  /// Every live flight's waiters, keyed by identity and then by ticket; an identity with an empty
  /// waiter table is still a live flight, because its exchange has not completed.
  private let flights = Mutex<[CoalescingIdentity: [UInt64: Waiter]]>([:])

  /// The source of each waiter's ticket: the identity its cancellation handler removes by.
  private let tickets = Atomic<UInt64>(0)

  init() {}

  /// Runs `work` once for every caller that arrives under `identity` while it is in flight, and
  /// returns its outcome to each of them.
  ///
  /// - Parameters:
  ///   - identity: The caller's key together with the credential the exchange goes out under.
  ///   - work: The exchange, run by the leader's flight and never by a joiner.
  /// - Returns: The response the flight's exchange produced.
  /// - Throws: ``TransportError/cancelled`` when this caller was cancelled while waiting or was
  ///   already cancelled on arrival, and otherwise whatever the exchange threw, to every waiter
  ///   alike.
  func run(
    _ identity: CoalescingIdentity,
    _ work: @escaping @Sendable () async throws(TransportError) -> Response
  ) async throws(TransportError) -> Response {
    let ticket = tickets.wrappingAdd(1, ordering: .relaxed).newValue

    let outcome: Outcome? = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: Waiter) in
        // The cancellation flag is read under the same lock the handler removes entries under, so a
        // cancellation that landed before this point is seen here and never registers, and one that
        // lands after it finds the entry to remove. Deciding lead-or-join in the same section
        // guarantees a flight cannot finish between the decision and the registration.
        let arrival: Arrival = flights.withLock { flights in
          guard !Task.isCancelled else { return .cancelled }
          let leads = flights[identity] == nil
          flights[identity, default: [:]][ticket] = continuation
          return leads ? .leads : .joins
        }
        switch arrival {
        case .cancelled:
          continuation.resume(returning: nil)
        case .joins:
          break
        case .leads:
          // Unstructured: no waiter's cancellation reaches the exchange, so a flight finishes for
          // whoever is still waiting, whichever caller started it.
          Task {
            let outcome: Outcome
            do throws(TransportError) {
              outcome = .success(try await work())
            } catch {
              outcome = .failure(error)
            }
            self.finish(identity, with: outcome)
          }
        }
      }
    } onCancel: {
      let waiter = flights.withLock { $0[identity]?.removeValue(forKey: ticket) }
      waiter?.resume(returning: nil)
    }

    guard let outcome else { throw .cancelled }
    return try outcome.get()
  }

  /// Ends the flight under `identity` and answers everyone still waiting on it.
  ///
  /// The flight is removed and its waiters taken in one critical section, so a caller that arrives
  /// afterwards leads a fresh exchange instead of registering with one that will never answer.
  private func finish(_ identity: CoalescingIdentity, with outcome: Outcome) {
    let waiters = flights.withLock { $0.removeValue(forKey: identity) ?? [:] }
    for waiter in waiters.values {
      waiter.resume(returning: outcome)
    }
  }
}
