import Synchronization

/// A single-reader view of a WebSocket's bounded completed-message inbox.
///
/// Creating a sequence or iterator starts no additional receive work. The first next() claims the
/// reader until completion, cancellation or release of the last iterator copy. Cancellation
/// preserves unread messages for a new iterator. Backend-reported closure drains the inbox; failures
/// discard it. Competing readers fail concurrentOperation without disturbing the owner.
public struct WebSocketMessages: AsyncSequence, Sendable {
  /// One complete text or binary message.
  public typealias Element = WebSocket.Message
  /// The typed lifecycle failure.
  public typealias Failure = WebSocketError

  /// A non-Sendable iterator whose copies share a reader claim and next-call exclusivity.
  public struct Iterator: AsyncIteratorProtocol {
    private let read: () async throws(WebSocketError) -> WebSocket.Message?

    fileprivate init(owner: WebSocketOwner) {
      let claim = WebSocketReader(owner: owner)
      read = { () throws(WebSocketError) in try await claim.next() }
    }

    /// Returns the next message, nil on normal completion, or a typed failure.
    ///
    /// Overlapping calls through copies throw concurrentOperation. If cancellation wins
    /// settlement it consumes no message and finishes this iterator; if delivery wins, the
    /// delivered message is returned so cancellation cannot silently discard it.
    public mutating func next(isolation actor: isolated (any Actor)? = #isolation)
      async throws(WebSocketError) -> WebSocket.Message?
    {
      try await read()
    }
  }

  private let owner: WebSocketOwner

  init(owner: WebSocketOwner) { self.owner = owner }

  /// Creates an unclaimed iterator that retains the connection.
  public func makeAsyncIterator() -> Iterator { Iterator(owner: owner) }
}

private final class WebSocketReader: Sendable {
  private struct State {
    var finished = false
    var pending = false
  }

  private let owner: WebSocketOwner
  private let state = Mutex(State())

  init(owner: WebSocketOwner) { self.owner = owner }

  deinit { owner.session.releaseReader(ObjectIdentifier(self)) }

  func next() async throws(WebSocketError) -> WebSocket.Message? {
    let admitted: Result<Bool, WebSocketError> = state.withLock { state in
      if state.pending { return .failure(WebSocketError(kind: .concurrentOperation)) }
      if state.finished { return .success(false) }
      state.pending = true
      return .success(true)
    }
    guard try admitted.get() else { return nil }
    do throws(WebSocketError) {
      let message = try await owner.session.next(reader: ObjectIdentifier(self))
      state.withLock {
        $0.pending = false
        $0.finished = message == nil
      }
      return message
    } catch {
      state.withLock {
        $0.pending = false
        $0.finished = error.kind != .concurrentOperation
      }
      throw error
    }
  }
}
