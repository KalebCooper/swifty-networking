#if WebSocketPortable
import NIOCore
import NIOWebSocket
import Synchronization
import WebSocketCore
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Thread-safe operation settlement; handlers and their contexts remain on the event loop.
final class NIOWebSocketExchange: Sendable {
  private struct State {
    var candidates: [ObjectIdentifier: any Channel] = [:]
    var channel: (any Channel)?
    var close: WebSocketClose?
    var closing = false
    var failure: WebSocketError?
    var ping: (UInt64, WebSocketCompletion<Void>)?
    var protocolName: String?
    var sequence: UInt64 = 0
  }

  let closing = WebSocketCompletion<WebSocketClose>()
  let inbox: WebSocketInbox
  private let mask: @Sendable () -> WebSocketMaskingKey
  let opening = WebSocketCompletion<Void>()
  let released = WebSocketCompletion<Void>()
  private let state = Mutex(State())

  init(
    mask: @escaping @Sendable () -> WebSocketMaskingKey = { .random() }, options: WebSocket.Options
  ) {
    self.mask = mask
    inbox = WebSocketInbox(options: options)
  }

  var channel: (any Channel)? { state.withLock { $0.channel } }
  var closeInfo: WebSocketClose? { state.withLock { $0.close } }
  var negotiatedSubprotocol: String? { state.withLock { $0.protocolName } }

  func attach(_ channel: any Channel) {
    let rejected = state.withLock { state in
      state.channel = channel
      return state.failure != nil
    }
    channel.closeFuture.whenComplete { _ in
      self.fail(WebSocketError(kind: .transport))
    }
    if rejected { channel.close(promise: nil) }
  }

  func cancel() {
    fail(WebSocketError(kind: .cancelled))
    let channels = state.withLock { Array($0.candidates.values) }
    for channel in channels { channel.close(promise: nil) }
  }

  func close(code: WebSocket.CloseCode, reason: String?) async throws(WebSocketError)
    -> WebSocketClose
  {
    let starts = state.withLock { state in
      guard !state.closing, state.failure == nil, state.close == nil else { return false }
      state.closing = true
      return true
    }
    if starts {
      var bytes = ByteBuffer()
      bytes.writeInteger(code.rawValue)
      if let reason { bytes.writeString(reason) }
      write(opcode: .connectionClose, payload: bytes).whenFailure { self.fail(Self.error($0)) }
    }
    return try await closing.wait()
  }

  static func error(_ error: any Error) -> WebSocketError {
    if let error = error as? WebSocketError { return error }
    if let error = error as? NIOWebSocketError {
      return WebSocketError(
        kind: error == .invalidFrameLength ? .messageTooLarge : .protocolViolation,
        underlying: error)
    }
    return WebSocketError(kind: .transport, underlying: error)
  }

  func fail(_ error: WebSocketError) {
    let effects = state.withLock { state -> ((any Channel)?, WebSocketCompletion<Void>?, Bool) in
      guard state.failure == nil, state.close == nil else { return (nil, nil, false) }
      state.failure = error
      let ping = state.ping?.1
      state.ping = nil
      return (state.channel, ping, true)
    }
    guard effects.2 else { return }
    opening.finish(.failure(error))
    closing.finish(.failure(error))
    effects.1?.finish(.failure(error))
    inbox.finish(.failure(error))
    effects.0?.close(promise: nil)
  }

  func opened(protocolName: String?) {
    let active = state.withLock { state in
      state.protocolName = protocolName
      return state.failure == nil
    }
    if active { opening.finish(.success(())) }
  }

  func peerClosed(_ close: WebSocketClose, payload: ByteBuffer) {
    let effects = state.withLock { state -> (Bool, WebSocketCompletion<Void>?)? in
      guard state.failure == nil, state.close == nil else { return nil }
      state.close = close
      let echo = !state.closing
      state.closing = true
      let ping = state.ping?.1
      state.ping = nil
      return (echo, ping)
    }
    guard let effects else { return }
    effects.1?.finish(.failure(WebSocketError(close: close, kind: .closed)))
    let channel = state.withLock { $0.channel }
    // The close handshake is complete once both close frames have crossed. Closing the channel
    // then sends a TLS closure alert that a peer may never answer, so the result does not wait for
    // the channel to finish closing. `released` still tracks that for shutdown.
    let finish: @Sendable (Result<WebSocketClose, WebSocketError>) -> Void = { result in
      self.closing.finish(result)
      self.inbox.finish(result)
      channel?.close(promise: nil)
    }
    if effects.0 {
      write(opcode: .connectionClose, payload: payload).whenComplete { result in
        finish(result.map { close }.mapError(Self.error))
      }
    } else {
      finish(.success(close))
    }
  }

  func ping() async throws(WebSocketError) {
    let completion = WebSocketCompletion<Void>()
    let token: Result<UInt64, WebSocketError> = state.withLock { state in
      if let failure = state.failure { return .failure(failure) }
      guard !state.closing else { return .failure(WebSocketError(kind: .closed)) }
      guard state.ping == nil else { return .failure(WebSocketError(kind: .concurrentOperation)) }
      state.sequence &+= 1
      state.ping = (state.sequence, completion)
      return .success(state.sequence)
    }
    var payload = ByteBuffer()
    payload.writeInteger(try token.get())
    write(opcode: .ping, payload: payload).whenFailure { self.fail(Self.error($0)) }
    try await completion.wait()
  }

  func pong(_ payload: ByteBuffer) {
    guard payload.readableBytes == 8,
      let token: UInt64 = payload.getInteger(at: payload.readerIndex)
    else { return }
    let completion = state.withLock { state -> WebSocketCompletion<Void>? in
      guard state.ping?.0 == token else { return nil }
      let completion = state.ping?.1
      state.ping = nil
      return completion
    }
    completion?.finish(.success(()))
  }

  func register(_ channel: any Channel) {
    let id = ObjectIdentifier(channel)
    let cancelled = state.withLock { state in
      state.candidates[id] = channel
      return state.failure != nil
    }
    channel.closeFuture.whenComplete { _ in
      _ = self.state.withLock { $0.candidates.removeValue(forKey: id) }
    }
    if cancelled { channel.close(promise: nil) }
  }

  func send(_ message: WebSocket.Message) async throws(WebSocketError) {
    var payload = ByteBuffer()
    let opcode: WebSocketOpcode
    switch message {
    case .binary(let data): opcode = .binary; payload.writeBytes(data)
    case .text(let text): opcode = .text; payload.writeString(text)
    }
    let completion = WebSocketCompletion<Void>()
    write(opcode: opcode, payload: payload).whenComplete { result in
      completion.finish(result.mapError(Self.error))
    }
    try await completion.wait()
  }

  func write(opcode: WebSocketOpcode, payload: ByteBuffer) -> EventLoopFuture<Void> {
    // Installed before any successful opening; callers never receive an unregistered connection.
    let channel = state.withLock { $0.channel }
    guard let channel else {
      preconditionFailure("Writing requires an attached channel")
    }
    if let error = state.withLock({ $0.failure }) {
      return channel.eventLoop.makeFailedFuture(error)
    }
    guard channel.isWritable else {
      return channel.eventLoop.makeFailedFuture(WebSocketError(kind: .bufferOverflow))
    }
    let frame = WebSocketFrame(fin: true, opcode: opcode, maskKey: mask(), data: payload)
    return channel.writeAndFlush(frame)
  }
}
#endif
