import Synchronization

/// Owns shared state, but never retains an external-owner token or iterator.
final class WebSocketSession: Sendable {
  private typealias PingWaiter = CheckedContinuation<Result<Void, WebSocketError>, Never>
  private typealias ReadWaiter = CheckedContinuation<
    Result<WebSocket.Message?, WebSocketError>, Never
  >

  private final class Probe: Sendable {}
  private final class ReadTicket: Sendable {}

  private struct State {
    var aborted = false
    var bufferedBytes = 0
    var cleanup = false
    var close: WebSocketClose?
    var inbox: [WebSocket.Message] = []
    var ping: Probe?
    var pingWaiter: PingWaiter?
    var reader: ObjectIdentifier?
    var readTicket: ReadTicket?
    var readWaiter: ReadWaiter?
    var tasks: [Work: Task<Void, Never>] = [:]
    var terminal: Result<Void, WebSocketError>?
  }

  private enum Work: Hashable {
    case cleanup
    case ping
    case pingTimer
    case receive
  }

  private let backend: any WebSocketConnection
  private let clock: WebSocketClock
  private let options: WebSocket.Options
  private let state = Mutex(State())

  init(backend: any WebSocketConnection, clock: WebSocketClock, options: WebSocket.Options) {
    self.backend = backend
    self.clock = clock
    self.options = options
  }

  var closeInfo: WebSocketClose? { state.withLock { $0.close } ?? backend.closeInfo }
  var negotiatedSubprotocol: String? { backend.negotiatedSubprotocol }

  func cancel() {
    terminate(.failure(WebSocketError(kind: .cancelled)))
    abort()
  }

  func next(reader: ObjectIdentifier) async throws(WebSocketError) -> WebSocket.Message? {
    let ticket = ReadTicket()
    let result: Result<WebSocket.Message?, WebSocketError> = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediate: Result<WebSocket.Message?, WebSocketError>? = state.withLock { state in
          if Task.isCancelled { return .failure(WebSocketError(kind: .cancelled)) }
          if let owner = state.reader, owner != reader {
            return .failure(WebSocketError(kind: .concurrentOperation))
          }
          if state.readWaiter != nil { return .failure(WebSocketError(kind: .concurrentOperation)) }
          state.reader = reader
          if !state.inbox.isEmpty {
            let message = state.inbox.removeFirst()
            state.bufferedBytes -= message.byteCount
            return .success(message)
          }
          if let terminal = state.terminal {
            state.reader = nil
            return terminal.map { nil }
          }
          state.readTicket = ticket
          state.readWaiter = continuation
          return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
      }
    } onCancel: {
      self.cancelRead(reader: reader, ticket: ticket)
    }
    // Settlement, rather than a later cancellation-flag read, owns message delivery.
    // Replacing a won message with cancelled here would silently lose that message.
    switch result {
    case .success(nil): releaseReader(reader)
    case .failure(let error) where error.kind != .concurrentOperation: releaseReader(reader)
    default: break
    }
    return try result.get()
  }

  func ping() async throws(WebSocketError) {
    let probe = Probe()
    let deadline = clock.now.advanced(by: options.pingTimeout)
    let result: Result<Void, WebSocketError> = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediate: Result<Void, WebSocketError>? = state.withLock { state in
          if Task.isCancelled { return .failure(WebSocketError(kind: .cancelled)) }
          if let terminal = state.terminal {
            return .failure(terminal.failure ?? WebSocketError(kind: .closed))
          }
          if state.ping != nil { return .failure(WebSocketError(kind: .concurrentOperation)) }
          state.ping = probe
          state.pingWaiter = continuation
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
              self.terminate(.failure(WebSocketError(kind: .timedOut)), expecting: probe)
            } catch {
              if !Task.isCancelled {
                self.terminate(
                  .failure(WebSocketError(kind: .transport, underlying: error)), expecting: probe)
              }
            }
          }, as: .pingTimer, probe: probe)
        attach(
          Task {
            guard self.isActive(probe), !Task.isCancelled else { return }
            do throws(WebSocketError) {
              try await backend.ping()
              self.finishPing(probe)
            } catch {
              self.terminate(.failure(error), expecting: probe)
            }
          }, as: .ping, probe: probe)
      }
    } onCancel: {
      let waiter = self.state.withLock { state -> PingWaiter? in
        guard state.ping === probe else { return nil }
        let waiter = state.pingWaiter
        state.pingWaiter = nil
        return waiter
      }
      waiter?.resume(returning: .failure(WebSocketError(kind: .cancelled)))
    }
    try result.get()
  }

  func releaseReader(_ reader: ObjectIdentifier) {
    let waiter = state.withLock { state -> ReadWaiter? in
      guard state.reader == reader else { return nil }
      state.reader = nil
      let waiter = state.readWaiter
      state.readTicket = nil
      state.readWaiter = nil
      return waiter
    }
    waiter?.resume(returning: .failure(WebSocketError(kind: .cancelled)))
  }

  func start() {
    attach(
      Task {
        do throws(WebSocketError) {
          while !Task.isCancelled {
            guard let message = try await backend.receive() else {
              guard let close = backend.closeInfo else {
                self.terminate(.failure(WebSocketError(kind: .protocolViolation)))
                return
              }
              self.terminate(.success(()), close: close)
              return
            }
            if !self.accept(message) { return }
          }
        } catch {
          self.terminate(.failure(error))
        }
      }, as: .receive)
  }

  private func abort() {
    let effects: (Bool, Task<Void, Never>?) = state.withLock { state in
      let first = !state.aborted
      state.aborted = true
      state.cleanup = false
      return (first, state.tasks.removeValue(forKey: .cleanup))
    }
    effects.1?.cancel()
    if effects.0 { backend.cancel() }
  }

  private func accept(_ message: WebSocket.Message) -> Bool {
    let count = message.byteCount
    let action: (Bool, ReadWaiter?, WebSocketError?) = state.withLock { state in
      guard state.terminal == nil else { return (false, nil, nil) }
      guard count <= options.maxMessageBytes else {
        return (false, nil, WebSocketError(kind: .messageTooLarge))
      }
      if let waiter = state.readWaiter {
        state.readTicket = nil
        state.readWaiter = nil
        return (true, waiter, nil)
      }
      // Subtraction is safe because both operands are nonnegative and existing admission
      // already established bufferedBytes <= maxBufferedBytes.
      guard state.inbox.count < options.maxBufferedMessages,
        count <= options.maxBufferedBytes - state.bufferedBytes
      else { return (false, nil, WebSocketError(kind: .bufferOverflow)) }
      state.inbox.append(message)
      state.bufferedBytes += count
      return (true, nil, nil)
    }
    action.1?.resume(returning: .success(message))
    if let error = action.2 { terminate(.failure(error), policyClose: true) }
    return action.0
  }

  private func attach(_ task: Task<Void, Never>, as work: Work, probe: Probe? = nil) {
    let reject = state.withLock { state in
      if work == .cleanup {
        guard state.cleanup else { return true }
      } else {
        guard state.terminal == nil else { return true }
        if let probe, state.ping !== probe { return true }
      }
      state.tasks[work] = task
      return false
    }
    if reject { task.cancel() }
  }

  private func cancelRead(reader: ObjectIdentifier, ticket: ReadTicket) {
    let waiter = state.withLock { state -> ReadWaiter? in
      // A cancellation handler may finish after its operation has returned. The iterator's
      // identity alone would allow that stale handler to cancel a later next() through a copy.
      guard state.reader == reader, state.readTicket === ticket else { return nil }
      state.reader = nil
      state.readTicket = nil
      let waiter = state.readWaiter
      state.readWaiter = nil
      return waiter
    }
    waiter?.resume(returning: .failure(WebSocketError(kind: .cancelled)))
  }

  private func finishPing(_ probe: Probe) {
    let effects: (PingWaiter?, [Task<Void, Never>]) = state.withLock { state in
      guard state.ping === probe else { return (nil, []) }
      let waiter = state.pingWaiter
      state.ping = nil
      state.pingWaiter = nil
      let tasks = [
        state.tasks.removeValue(forKey: .ping), state.tasks.removeValue(forKey: .pingTimer),
      ].compactMap { $0 }
      return (waiter, tasks)
    }
    for task in effects.1 { task.cancel() }
    effects.0?.resume(returning: .success(()))
  }

  private func isActive(_ probe: Probe) -> Bool {
    state.withLock { $0.terminal == nil && $0.ping === probe }
  }

  private func terminate(
    _ terminal: Result<Void, WebSocketError>,
    close: WebSocketClose? = nil,
    expecting probe: Probe? = nil,
    policyClose: Bool = false
  ) {
    let effects: (ReadWaiter?, PingWaiter?, [Task<Void, Never>])? = state.withLock { state in
      guard state.terminal == nil else { return nil }
      if let probe, state.ping !== probe { return nil }
      state.terminal = terminal
      state.close = close ?? terminal.failure?.close
      state.cleanup = policyClose
      if case .failure = terminal {
        state.inbox.removeAll()
        state.bufferedBytes = 0
      }
      let effects = (state.readWaiter, state.pingWaiter, Array(state.tasks.values))
      state.ping = nil
      state.pingWaiter = nil
      state.readTicket = nil
      state.readWaiter = nil
      state.tasks.removeAll()
      return effects
    }
    guard let effects else { return }
    for task in effects.2 { task.cancel() }
    effects.0?.resume(returning: terminal.map { nil })
    effects.1?.resume(
      returning: .failure(terminal.failure ?? WebSocketError(close: close, kind: .closed)))
    if policyClose {
      let deadline = clock.now.advanced(by: options.closeTimeout)
      attach(
        Task {
          let wait = WebSocketConnectWait<WebSocketClose>(discard: { _ in })
          do throws(WebSocketError) {
            _ = try await wait.run(clock: clock, deadline: deadline) { () throws(WebSocketError) in
              guard !Task.isCancelled else { throw WebSocketError(kind: .cancelled) }
              return try await self.backend.close(
                code: terminal.failure?.kind == .messageTooLarge
                  ? .init(rawValue: 1009) : .init(rawValue: 1008),
                reason: nil)
            }
          } catch {
            // The initiating resource failure stays authoritative, regardless of close outcome.
          }
          self.abort()
        }, as: .cleanup)
    } else {
      abort()
    }
  }
}

private extension Result where Success == Void, Failure == WebSocketError {
  var failure: WebSocketError? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
