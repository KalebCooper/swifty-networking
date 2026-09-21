#if canImport(Darwin)
import Foundation
import HTTPTypes
import Synchronization
import WebSocketCore

/// Holds callback state, without retaining the session owner or a consumer's socket.
final class URLSessionWebSocketExchange: Sendable {
  private struct State {
    var close: WebSocketClose?
    var closing = false
    var opened = false
    var ping: WebSocketCompletion<Void>?
    var read: WebSocketCompletion<WebSocket.Message?>?
    var selectedProtocol: String?
    var send: WebSocketCompletion<Void>?
    var terminal: Result<WebSocketClose, WebSocketError>?
  }

  let completion = WebSocketCompletion<WebSocketClose>()
  let opening = WebSocketCompletion<Void>()
  private let protocols: [String]
  private let state = Mutex(State())
  private let task: URLSessionWebSocketTask

  init(protocols: [String], task: URLSessionWebSocketTask) {
    self.protocols = protocols
    self.task = task
  }

  var closeInfo: WebSocketClose? { state.withLock { $0.close } }
  var negotiatedSubprotocol: String? { state.withLock { $0.selectedProtocol } }

  func cancel() {
    finish(.failure(WebSocketError(kind: .cancelled)))
    task.cancel()
  }

  func close(code: WebSocket.CloseCode, reason: String?)
    async throws(WebSocketError) -> WebSocketClose
  {
    guard let foundationCode = URLSessionWebSocketTask.CloseCode(rawValue: Int(code.rawValue)),
      ((1000...1014).contains(code.rawValue) && ![1004, 1005, 1006].contains(code.rawValue))
        || (3000...4999).contains(code.rawValue),
      (reason?.utf8.count ?? 0) <= 123
    else { throw WebSocketError(kind: .invalidRequest) }
    guard !Task.isCancelled else { throw WebSocketError(kind: .cancelled) }
    let starts = state.withLock { state in
      guard state.terminal == nil, !state.closing else { return false }
      state.closing = true
      return true
    }
    if starts { task.cancel(with: foundationCode, reason: reason.map { Data($0.utf8) }) }
    return try await completion.wait()
  }

  func complete(error: (any Error)?, response: HTTPResponse?) {
    let result: Result<WebSocketClose, WebSocketError> = state.withLock { state in
      if let terminal = state.terminal { return terminal }
      guard state.opened else {
        return .failure(
          WebSocketError(kind: .handshakeRejected, response: response, underlying: error))
      }
      if let error { return .failure(Self.failure(error)) }
      guard let close = state.close else {
        return .failure(WebSocketError(kind: .transport))
      }
      return .success(close)
    }
    finish(result)
  }

  private static func failure(_ error: any Error) -> WebSocketError {
    let diagnostic = error as NSError
    if diagnostic.domain == NSPOSIXErrorDomain {
      if diagnostic.code == POSIXError.Code.EMSGSIZE.rawValue {
        return WebSocketError(kind: .messageTooLarge, underlying: error)
      }
      if diagnostic.code == POSIXError.Code.EPROTO.rawValue {
        return WebSocketError(kind: .protocolViolation, underlying: error)
      }
    }
    let kind: WebSocketError.Kind
    switch (error as? URLError)?.code {
    case .cancelled: kind = .cancelled
    case .dataLengthExceedsMaximum: kind = .messageTooLarge
    case .timedOut: kind = .timedOut
    default: kind = .transport
    }
    return WebSocketError(kind: kind, underlying: error)
  }

  private func finish(_ result: Result<WebSocketClose, WebSocketError>) {
    let pending = state.withLock { state -> State? in
      guard state.terminal == nil else { return nil }
      state.terminal = result
      let pending = state
      state.ping = nil
      state.read = nil
      state.send = nil
      return pending
    }
    guard let pending else { return }
    let error: WebSocketError
    switch result {
    case .failure(let failure): error = failure
    case .success: error = WebSocketError(kind: .closed)
    }
    opening.finish(.failure(error))
    completion.finish(result)
    pending.ping?.finish(.failure(error))
    pending.read?.finish(result.map { _ in nil })
    pending.send?.finish(.failure(error))
  }

  func open(protocol selected: String?) {
    if let selected, !protocols.contains(selected) {
      finish(.failure(WebSocketError(kind: .handshakeRejected)))
      task.cancel()
      return
    }
    let accepted = state.withLock { state in
      guard state.terminal == nil else { return false }
      state.opened = true
      state.selectedProtocol = selected
      return true
    }
    if accepted { opening.finish(.success(())) } else { task.cancel() }
  }

  private static func operationFailure(
    _ terminal: Result<WebSocketClose, WebSocketError>
  ) -> WebSocketError {
    switch terminal {
    case .failure(let error): error
    case .success: WebSocketError(kind: .closed)
    }
  }

  func ping() async throws(WebSocketError) {
    let result = WebSocketCompletion<Void>()
    let error = state.withLock { state -> WebSocketError? in
      if Task.isCancelled { return WebSocketError(kind: .cancelled) }
      if let terminal = state.terminal { return Self.operationFailure(terminal) }
      guard state.ping == nil else { return WebSocketError(kind: .concurrentOperation) }
      state.ping = result
      return nil
    }
    if let error { throw error }
    task.sendPing { error in
      let current = self.state.withLock { state in
        guard state.ping === result else { return false }
        state.ping = nil
        return true
      }
      if current { result.finish(error.map { .failure(Self.failure($0)) } ?? .success(())) }
    }
    try await result.wait()
  }

  func receive() async throws(WebSocketError) -> WebSocket.Message? {
    let result = WebSocketCompletion<WebSocket.Message?>()
    let immediate = state.withLock { state -> Result<WebSocket.Message?, WebSocketError>? in
      if Task.isCancelled { return .failure(WebSocketError(kind: .cancelled)) }
      if let terminal = state.terminal { return terminal.map { _ in nil } }
      guard state.read == nil else {
        return .failure(WebSocketError(kind: .concurrentOperation))
      }
      state.read = result
      return nil
    }
    if let immediate { return try immediate.get() }
    task.receive { received in
      switch received {
      case .failure:
        // Receive failure can precede didClose. Task completion settles the read after metadata.
        break
      case .success(let message):
        let value: WebSocket.Message
        switch message {
        case .data(let data): value = .binary(data)
        case .string(let text): value = .text(text)
        @unknown default:
          self.finish(.failure(WebSocketError(kind: .protocolViolation)))
          self.task.cancel()
          return
        }
        let current = self.state.withLock { state in
          guard state.read === result else { return false }
          state.read = nil
          return true
        }
        if current { result.finish(.success(value)) }
      }
    }
    return try await result.wait()
  }

  func recordClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    let raw = code.rawValue
    guard
      raw == 1005 || ((1000...1014).contains(raw) && ![1004, 1006].contains(raw))
        || (3000...4999).contains(raw)
    else { return }
    let text = reason.flatMap { String(data: $0, encoding: .utf8) }
    guard reason == nil || text != nil else { return }
    state.withLock { state in
      guard state.terminal == nil else { return }
      state.close = WebSocketClose(
        code: raw == 1005 ? nil : .init(rawValue: UInt16(raw)),
        reason: text?.isEmpty == true ? nil : text)
    }
  }

  func reject(response: HTTPResponse?) {
    finish(.failure(WebSocketError(kind: .handshakeRejected, response: response)))
    task.cancel()
  }

  func send(_ message: WebSocket.Message) async throws(WebSocketError) {
    let result = WebSocketCompletion<Void>()
    let error = state.withLock { state -> WebSocketError? in
      if Task.isCancelled { return WebSocketError(kind: .cancelled) }
      if let terminal = state.terminal { return Self.operationFailure(terminal) }
      guard !state.closing else { return WebSocketError(kind: .closed) }
      guard state.send == nil else { return WebSocketError(kind: .concurrentOperation) }
      state.send = result
      return nil
    }
    if let error { throw error }
    let outgoing: URLSessionWebSocketTask.Message
    switch message {
    case .binary(let data): outgoing = .data(data)
    case .text(let text): outgoing = .string(text)
    }
    task.send(outgoing) { error in
      let current = self.state.withLock { state in
        guard state.send === result else { return false }
        state.send = nil
        return true
      }
      if current { result.finish(error.map { .failure(Self.failure($0)) } ?? .success(())) }
    }
    try await result.wait()
  }

}
#endif
