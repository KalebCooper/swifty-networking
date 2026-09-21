import Synchronization

/// Owns shared state, but never retains an external-owner token or iterator.
final class WebSocketSession: Sendable {
  private typealias PingWaiter = CheckedContinuation<Result<Void, WebSocketError>, Never>
  private typealias ReadWaiter = CheckedContinuation<
    Result<WebSocket.Message?, WebSocketError>, Never
  >

  private final class CloseAttempt: Sendable {
    let code: WebSocket.CloseCode
    let completion = WebSocketCompletion<WebSocketClose>()
    let deadline: WebSocketClock.Instant
    let reason: String?

    init(code: WebSocket.CloseCode, deadline: WebSocketClock.Instant, reason: String?) {
      self.code = code
      self.deadline = deadline
      self.reason = reason
    }
  }

  private struct Effects {
    var abort = false
    var completions: [@Sendable () -> Void] = []
    var policyClose: WebSocketError?
    var tasks: [Task<Void, Never>] = []
    var timer: SendTimer?
  }

  private final class Probe: Sendable {}
  private final class ReadTicket: Sendable {}

  private struct SendEntry {
    let completion: WebSocketCompletion<Void>
    let deadline: WebSocketClock.Instant
    let failurePolicy: WebSocket.SendFailurePolicy
    let message: WebSocket.Message
    let ticket: SendTicket
  }

  private final class SendTicket: Sendable {}

  private final class SendTimer: Sendable {
    let deadline: WebSocketClock.Instant

    init(deadline: WebSocketClock.Instant) { self.deadline = deadline }
  }

  private struct State {
    var aborted = false
    var bufferedBytes = 0
    var cleanup = false
    var close: WebSocketClose?
    var closeStarted = false
    var closing: CloseAttempt?
    var inbox: [WebSocket.Message] = []
    var pendingSendBytes = 0
    var ping: Probe?
    var pingWaiter: PingWaiter?
    var reader: ObjectIdentifier?
    var readTicket: ReadTicket?
    var readWaiter: ReadWaiter?
    var sends: [SendEntry] = []
    var sendTimer: SendTimer?
    var tasks: [Work: Task<Void, Never>] = [:]
    var terminal: Result<Void, WebSocketError>?
    var writing: SendTicket?
  }

  private enum Work: Hashable {
    case cleanup
    case closeTimer
    case ping
    case pingTimer
    case receive
    case sendTimer
    case writer
  }

  private enum Write {
    case close(CloseAttempt)
    case send(WebSocket.Message, SendTicket)
  }

  private let backend: any WebSocketConnection
  private let clock: WebSocketClock
  private let options: WebSocket.Options
  private let state = Mutex(State())
  private let writes: AsyncStream<Void>
  private let writeSignal: AsyncStream<Void>.Continuation

  init(backend: any WebSocketConnection, clock: WebSocketClock, options: WebSocket.Options) {
    self.backend = backend
    self.clock = clock
    self.options = options
    (writes, writeSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  var closeInfo: WebSocketClose? { state.withLock { $0.close } ?? backend.closeInfo }
  var negotiatedSubprotocol: String? { backend.negotiatedSubprotocol }

  func cancel() {
    terminate(.failure(WebSocketError(kind: .cancelled)))
    abort()
  }

  func close(
    cancellation: WebSocket.CloseCancellationPolicy, code: WebSocket.CloseCode, reason: String?
  ) async throws(WebSocketError) -> WebSocketClose {
    let raw = code.rawValue
    guard
      ((1000...1014).contains(raw) && ![1004, 1005, 1006].contains(raw))
        || (3000...4999).contains(raw)
    else { throw WebSocketError(kind: .invalidRequest) }
    guard (reason?.utf8.count ?? 0) <= 123 else { throw WebSocketError(kind: .invalidRequest) }
    var effects = Effects()
    var starts = false
    let admitted: Result<CloseAttempt, WebSocketError> = state.withLock { state in
      if Task.isCancelled { return .failure(WebSocketError(kind: .cancelled)) }
      if let closing = state.closing { return .success(closing) }
      let attempt = CloseAttempt(
        code: code, deadline: clock.now.advanced(by: options.closeTimeout), reason: reason)
      if let terminal = state.terminal {
        if let error = terminal.failure { return .failure(error) }
        guard let close = state.close else {
          return .failure(WebSocketError(kind: .closed))
        }
        effects.completions.append { attempt.completion.finish(.success(close)) }
        return .success(attempt)
      }
      state.closing = attempt
      starts = true
      let queued = state.writing == nil ? state.sends : Array(state.sends.dropFirst())
      for entry in queued {
        let completion = entry.completion
        effects.completions.append { completion.finish(.failure(WebSocketError(kind: .closed))) }
        state.pendingSendBytes -= entry.message.byteCount
      }
      state.sends.removeLast(queued.count)
      refreshSendTimer(&state, effects: &effects)
      return .success(attempt)
    }
    apply(effects)
    let attempt = try admitted.get()
    if starts {
      attach(
        Task {
          do {
            try await clock.sleep(until: attempt.deadline, tolerance: nil)
            self.failClose(attempt, error: WebSocketError(kind: .timedOut))
          } catch {
            if !Task.isCancelled {
              self.failClose(attempt, error: WebSocketError(kind: .transport, underlying: error))
            }
          }
        }, as: .closeTimer)
      writeSignal.yield(())
    }
    let result: Result<WebSocketClose, WebSocketError> = await withTaskCancellationHandler {
      do throws(WebSocketError) {
        return .success(try await attempt.completion.wait())
      } catch {
        return .failure(error)
      }
    } onCancel: {
      if cancellation == .abortConnection {
        self.failClose(attempt, error: WebSocketError(kind: .cancelled))
      }
    }
    guard !Task.isCancelled else { throw WebSocketError(kind: .cancelled) }
    return try result.get()
  }

  func enqueue(
    _ message: WebSocket.Message,
    failurePolicy: WebSocket.SendFailurePolicy?,
    policy: WebSocket.SendPolicy?
  ) throws(WebSocketError) -> WebSocket.SendOperation {
    let completion = WebSocketCompletion<Void>()
    let ticket = SendTicket()
    var effects = Effects()
    let error: WebSocketError? = state.withLock { state in
      if let terminal = state.terminal {
        return Task.isCancelled
          ? WebSocketError(kind: .cancelled)
          : terminal.failure ?? WebSocketError(kind: .closed)
      }
      if state.closing != nil {
        return WebSocketError(kind: Task.isCancelled ? .cancelled : .closed)
      }
      let failurePolicy = failurePolicy ?? options.sendFailurePolicy
      let policy = policy ?? options.sendPolicy
      let failure: WebSocketError?
      if Task.isCancelled {
        failure = WebSocketError(kind: .cancelled)
      } else if message.byteCount > options.maxMessageBytes {
        failure = WebSocketError(kind: .messageTooLarge)
      } else if policy == .rejectOverlapping && !state.sends.isEmpty {
        failure = WebSocketError(kind: .concurrentOperation)
      } else if state.sends.count >= options.maxPendingSendMessages
        || message.byteCount > options.maxPendingSendBytes - state.pendingSendBytes
      {
        failure = WebSocketError(kind: .sendQueueFull)
      } else {
        failure = nil
      }
      if let failure {
        if failurePolicy == .abortConnection {
          terminate(&state, with: .failure(failure), effects: &effects)
        }
        return failure
      }
      state.sends.append(
        SendEntry(
          completion: completion, deadline: clock.now.advanced(by: options.sendTimeout),
          failurePolicy: failurePolicy, message: message, ticket: ticket))
      state.pendingSendBytes += message.byteCount
      refreshSendTimer(&state, effects: &effects)
      return nil
    }
    apply(effects)
    if let error { throw error }
    writeSignal.yield(())
    return WebSocket.SendOperation(
      cancellation: { [weak self] in self?.failSend(ticket, error: WebSocketError(kind: .cancelled))
      },
      completion: completion)
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
        for await _ in writes {
          while let write = self.nextWrite() {
            guard !Task.isCancelled else { return }
            switch write {
            case .close(let attempt):
              do throws(WebSocketError) {
                let close = try await backend.close(code: attempt.code, reason: attempt.reason)
                self.terminate(.success(()), close: close)
              } catch {
                self.failClose(attempt, error: error)
              }
            case .send(let message, let ticket):
              do throws(WebSocketError) {
                try await backend.send(message)
                self.finishSend(ticket)
              } catch {
                self.failSend(ticket, error: error)
              }
            }
          }
        }
      }, as: .writer)
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

  private func apply(_ effects: Effects) {
    for task in effects.tasks { task.cancel() }
    if effects.abort { abort() }
    for completion in effects.completions { completion() }
    if let timer = effects.timer {
      let task = Task {
        do {
          try await clock.sleep(until: timer.deadline, tolerance: nil)
          self.expireSends(timer)
        } catch {
          if !Task.isCancelled {
            self.failSendTimer(timer, error: WebSocketError(kind: .transport, underlying: error))
          }
        }
      }
      let rejected = state.withLock { state in
        guard state.terminal == nil, state.sendTimer === timer else { return true }
        state.tasks[.sendTimer] = task
        return false
      }
      if rejected { task.cancel() }
    }
    if let error = effects.policyClose {
      let deadline = clock.now.advanced(by: options.closeTimeout)
      attach(
        Task {
          let wait = WebSocketConnectWait<WebSocketClose>(discard: { _ in })
          do throws(WebSocketError) {
            _ = try await wait.run(clock: clock, deadline: deadline) { () throws(WebSocketError) in
              guard !Task.isCancelled else { throw WebSocketError(kind: .cancelled) }
              return try await self.backend.close(
                code: error.kind == .messageTooLarge
                  ? .init(rawValue: 1009) : .init(rawValue: 1008), reason: nil)
            }
          } catch {
            // The initiating resource failure stays authoritative.
          }
          self.abort()
        }, as: .cleanup)
    }
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

  private func expireSends(_ timer: SendTimer) {
    var effects = Effects()
    state.withLock { state in
      guard state.sendTimer === timer else { return }
      while let entry = state.sends.first, entry.deadline <= clock.now {
        failSend(
          &state, effects: &effects, error: WebSocketError(kind: .timedOut), ticket: entry.ticket)
      }
      refreshSendTimer(&state, effects: &effects)
    }
    apply(effects)
  }

  private func failClose(_ attempt: CloseAttempt, error: WebSocketError) {
    var effects = Effects()
    state.withLock { state in
      guard state.closing === attempt else { return }
      terminate(&state, with: .failure(error), effects: &effects)
    }
    apply(effects)
  }

  private func failSend(_ ticket: SendTicket, error: WebSocketError) {
    var effects = Effects()
    state.withLock { state in
      failSend(&state, effects: &effects, error: error, ticket: ticket)
      refreshSendTimer(&state, effects: &effects)
    }
    apply(effects)
    writeSignal.yield(())
  }

  private func failSend(
    _ state: inout State, effects: inout Effects, error: WebSocketError, ticket: SendTicket
  ) {
    guard let index = state.sends.firstIndex(where: { $0.ticket === ticket }) else { return }
    let entry = state.sends[index]
    if state.writing === ticket || entry.failurePolicy == .abortConnection {
      terminate(&state, with: .failure(error), effects: &effects)
    } else {
      state.sends.remove(at: index)
      state.pendingSendBytes -= entry.message.byteCount
      let completion = entry.completion
      effects.completions.append { completion.finish(.failure(error)) }
    }
  }

  private func failSendTimer(_ timer: SendTimer, error: WebSocketError) {
    var effects = Effects()
    state.withLock { state in
      guard state.sendTimer === timer else { return }
      terminate(&state, with: .failure(error), effects: &effects)
    }
    apply(effects)
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

  private func finishSend(_ ticket: SendTicket) {
    var effects = Effects()
    state.withLock { state in
      guard state.writing === ticket, let entry = state.sends.first else { return }
      state.writing = nil
      state.sends.removeFirst()
      state.pendingSendBytes -= entry.message.byteCount
      let completion = entry.completion
      effects.completions.append { completion.finish(.success(())) }
      refreshSendTimer(&state, effects: &effects)
    }
    apply(effects)
  }

  private func isActive(_ probe: Probe) -> Bool {
    state.withLock { $0.terminal == nil && $0.ping === probe }
  }

  private func nextWrite() -> Write? {
    var effects = Effects()
    let write = state.withLock { state -> Write? in
      guard state.terminal == nil else { return nil }
      if let closing = state.closing {
        guard !state.closeStarted else { return nil }
        if closing.deadline <= clock.now {
          terminate(&state, with: .failure(WebSocketError(kind: .timedOut)), effects: &effects)
          return nil
        }
        state.closeStarted = true
        return .close(closing)
      }
      while let entry = state.sends.first {
        if entry.deadline <= clock.now {
          failSend(
            &state, effects: &effects, error: WebSocketError(kind: .timedOut), ticket: entry.ticket)
          continue
        }
        state.writing = entry.ticket
        refreshSendTimer(&state, effects: &effects)
        return .send(entry.message, entry.ticket)
      }
      refreshSendTimer(&state, effects: &effects)
      return nil
    }
    apply(effects)
    return write
  }

  private func refreshSendTimer(_ state: inout State, effects: inout Effects) {
    let deadline = state.sends.first?.deadline
    guard deadline != state.sendTimer?.deadline else { return }
    if let task = state.tasks.removeValue(forKey: .sendTimer) { effects.tasks.append(task) }
    state.sendTimer = deadline.map { SendTimer(deadline: $0) }
    effects.timer = state.sendTimer
  }

  private func terminate(
    _ terminal: Result<Void, WebSocketError>,
    close: WebSocketClose? = nil,
    expecting probe: Probe? = nil,
    policyClose: Bool = false
  ) {
    var effects = Effects()
    state.withLock { state in
      if let probe, state.ping !== probe { return }
      terminate(&state, with: terminal, close: close, effects: &effects, policyClose: policyClose)
    }
    apply(effects)
  }

  // State and its terminal transition form the primary argument pair; modifiers follow alphabetically.
  private func terminate(
    _ state: inout State,
    with terminal: Result<Void, WebSocketError>,
    close: WebSocketClose? = nil,
    effects: inout Effects,
    policyClose: Bool = false
  ) {
    guard state.terminal == nil else { return }
    state.terminal = terminal
    state.close = close ?? terminal.failure?.close
    // A partially written message cannot safely be followed by a policy close frame.
    let safePolicyClose = policyClose && state.writing == nil && !state.closeStarted
    state.cleanup = safePolicyClose
    if case .failure = terminal {
      state.inbox.removeAll()
      state.bufferedBytes = 0
    }
    effects.tasks += state.tasks.values
    state.tasks.removeAll()
    if let waiter = state.readWaiter {
      effects.completions.append { waiter.resume(returning: terminal.map { nil }) }
    }
    let error = terminal.failure ?? WebSocketError(close: state.close, kind: .closed)
    if let waiter = state.pingWaiter {
      effects.completions.append { waiter.resume(returning: .failure(error)) }
    }
    if let closing = state.closing {
      let result: Result<WebSocketClose, WebSocketError> =
        terminal.failure.map { .failure($0) }
        ?? state.close.map { .success($0) }
        ?? .failure(WebSocketError(kind: .closed))
      effects.completions.append { closing.completion.finish(result) }
    }
    for entry in state.sends {
      let completion = entry.completion
      effects.completions.append { completion.finish(.failure(error)) }
    }
    state.pendingSendBytes = 0
    state.ping = nil
    state.pingWaiter = nil
    state.readTicket = nil
    state.readWaiter = nil
    state.sends.removeAll()
    state.sendTimer = nil
    state.writing = nil
    effects.timer = nil
    effects.completions.append { self.writeSignal.finish() }
    if safePolicyClose {
      effects.policyClose = terminal.failure
    } else {
      effects.abort = true
    }
  }

}

private extension Result where Success == Void, Failure == WebSocketError {
  var failure: WebSocketError? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
