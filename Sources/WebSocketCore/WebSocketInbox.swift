import Synchronization

/// Event-loop backends deliver directly into the session's inbox.
package protocol WebSocketBufferedConnection: WebSocketConnection {
  var inbox: WebSocketInbox { get }
}

/// The shared bounded inbox for pull-based and event-loop backends.
package final class WebSocketInbox: Sendable {
  private typealias Waiter = CheckedContinuation<Result<WebSocket.Message?, WebSocketError>, Never>

  private struct State {
    var bufferedBytes = 0
    var handler: (@Sendable (Result<WebSocketClose, WebSocketError>) -> Void)?
    var messages: [WebSocket.Message] = []
    var reader: ObjectIdentifier?
    var terminal: Result<WebSocketClose, WebSocketError>?
    var ticket: ObjectIdentifier?
    var waiter: Waiter?
  }

  private final class Ticket: Sendable {}

  private let options: WebSocket.Options
  private let state = Mutex(State())

  package init(options: WebSocket.Options) { self.options = options }

  package func finish(_ result: Result<WebSocketClose, WebSocketError>) {
    let effects = state.withLock {
      state -> (Waiter?, (@Sendable (Result<WebSocketClose, WebSocketError>) -> Void)?) in
      guard state.terminal == nil else { return (nil, nil) }
      state.terminal = result
      if case .failure = result {
        state.messages.removeAll()
        state.bufferedBytes = 0
      }
      let waiter = state.waiter
      let handler = state.handler
      state.handler = nil
      state.ticket = nil
      state.waiter = nil
      return (waiter, handler)
    }
    effects.0?.resume(returning: result.map { _ in nil })
    effects.1?(result)
  }

  package func next(reader: ObjectIdentifier) async throws(WebSocketError) -> WebSocket.Message? {
    let ticket = Ticket()
    let result: Result<WebSocket.Message?, WebSocketError> = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediate = state.withLock { state -> Result<WebSocket.Message?, WebSocketError>? in
          if Task.isCancelled { return .failure(WebSocketError(kind: .cancelled)) }
          if let owner = state.reader, owner != reader {
            return .failure(WebSocketError(kind: .concurrentOperation))
          }
          guard state.waiter == nil else {
            return .failure(WebSocketError(kind: .concurrentOperation))
          }
          state.reader = reader
          if !state.messages.isEmpty {
            let message = state.messages.removeFirst()
            state.bufferedBytes -= message.byteCount
            return .success(message)
          }
          if let terminal = state.terminal {
            state.reader = nil
            return terminal.map { _ in nil }
          }
          state.ticket = ObjectIdentifier(ticket)
          state.waiter = continuation
          return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
      }
    } onCancel: {
      let waiter = self.state.withLock { state -> Waiter? in
        guard state.reader == reader, state.ticket == ObjectIdentifier(ticket) else { return nil }
        let waiter = state.waiter
        state.reader = nil
        state.ticket = nil
        state.waiter = nil
        return waiter
      }
      waiter?.resume(returning: .failure(WebSocketError(kind: .cancelled)))
    }
    switch result {
    case .success(nil): releaseReader(reader)
    case .failure(let error) where error.kind != .concurrentOperation: releaseReader(reader)
    default: break
    }
    return try result.get()
  }

  @discardableResult
  package func offer(_ message: WebSocket.Message) -> Bool {
    let action = state.withLock { state -> (Bool, Waiter?, WebSocketError?) in
      guard state.terminal == nil else { return (false, nil, nil) }
      guard message.byteCount <= options.maxMessageBytes else {
        return (false, nil, WebSocketError(kind: .messageTooLarge))
      }
      if let waiter = state.waiter {
        state.ticket = nil
        state.waiter = nil
        return (true, waiter, nil)
      }
      guard state.messages.count < options.maxBufferedMessages,
        message.byteCount <= options.maxBufferedBytes - state.bufferedBytes
      else { return (false, nil, WebSocketError(kind: .bufferOverflow)) }
      state.messages.append(message)
      state.bufferedBytes += message.byteCount
      return (true, nil, nil)
    }
    action.1?.resume(returning: .success(message))
    if let error = action.2 { finish(.failure(error)) }
    return action.0
  }

  package func onFinish(
    _ handler: @escaping @Sendable (Result<WebSocketClose, WebSocketError>) -> Void
  ) {
    let terminal = state.withLock { state -> Result<WebSocketClose, WebSocketError>? in
      if let terminal = state.terminal { return terminal }
      state.handler = handler
      return nil
    }
    if let terminal { handler(terminal) }
  }

  package func releaseReader(_ reader: ObjectIdentifier) {
    let waiter = state.withLock { state -> Waiter? in
      guard state.reader == reader else { return nil }
      state.reader = nil
      let waiter = state.waiter
      state.ticket = nil
      state.waiter = nil
      return waiter
    }
    waiter?.resume(returning: .failure(WebSocketError(kind: .cancelled)))
  }
}
