#if WebSocketHummingbird
#if os(Linux) || os(macOS)
import NIOCore
import NIOHTTP1
import NIOWebSocket
import Synchronization
import WebSocketCore
import WSCore
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// One borrowed Hummingbird channel with the shared session's bounded inbox.
final class HummingbirdWebSocketConnection: WebSocketBufferedConnection {
  private struct State {
    var close: WebSocketClose?
    var failed = false
    var fragmentedBytes: Int?
    var ping: (UInt64, WebSocketCompletion<Void>)?
    var sequence: UInt64 = 0
    var started = false
    var writer: WebSocketOutboundWriter?
  }

  let inbox: WebSocketInbox
  private let channel: any Channel
  private let maxMessageBytes: Int
  private let protocolName: String?
  private let state = Mutex(State())

  init(channel: any Channel, options: WebSocket.Options, protocolName: String?) {
    self.channel = channel
    maxMessageBytes = options.maxMessageBytes
    self.protocolName = protocolName
    inbox = WebSocketInbox(options: options)
    channel.closeFuture.whenComplete { [weak self] _ in self?.channelClosed() }
  }

  var closeInfo: WebSocketClose? { state.withLock { $0.close } }
  var negotiatedSubprotocol: String? { protocolName }

  func attach(_ writer: WebSocketOutboundWriter) throws(WebSocketError) {
    let accepted = state.withLock { state in
      guard !state.started, !state.failed else { return false }
      state.started = true
      state.writer = writer
      return true
    }
    guard accepted else { throw WebSocketError(kind: .closed) }
  }

  func cancel() {
    let ping = state.withLock { state -> WebSocketCompletion<Void>? in
      guard !state.failed else { return nil }
      state.failed = true
      state.writer = nil
      let ping = state.ping?.1
      state.ping = nil
      return ping
    }
    ping?.finish(.failure(WebSocketError(kind: .cancelled)))
    inbox.finish(.failure(WebSocketError(kind: .cancelled)))
    channel.close(promise: nil)
  }

  private func channelClosed() {
    let effects = state.withLock { state -> (Bool, WebSocketCompletion<Void>?) in
      state.failed = true
      state.writer = nil
      let ping = state.ping?.1
      state.ping = nil
      return (state.started, ping)
    }
    effects.1?.finish(.failure(WebSocketError(kind: .closed)))
    if !effects.0 { inbox.finish(.failure(WebSocketError(kind: .closed))) }
  }

  func close(code: WebSocket.CloseCode, reason: String?) async throws(WebSocketError)
    -> WebSocketClose
  {
    let writer = try currentWriter()
    do {
      try await writer.close(.init(codeNumber: Int(code.rawValue)), reason: reason)
      let reported = WebSocketClose(code: code, reason: reason)
      return state.withLock { state in
        if state.close == nil { state.close = reported }
        return state.close ?? reported
      }
    } catch { throw Self.error(error) }
  }

  private func currentWriter() throws(WebSocketError) -> WebSocketOutboundWriter {
    try state.withLock { state throws(WebSocketError) in
      guard !state.failed, let writer = state.writer else {
        throw WebSocketError(kind: .closed)
      }
      return writer
    }
  }

  private static func error(_ error: any Error) -> WebSocketError {
    if let error = error as? WebSocketError { return error }
    if error is CancellationError { return WebSocketError(kind: .cancelled) }
    if let error = error as? NIOWebSocketError {
      return WebSocketError(
        kind: error == .invalidFrameLength ? .messageTooLarge : .protocolViolation,
        underlying: error)
    }
    return WebSocketError(kind: .transport, underlying: error)
  }

  func failedUpgrade(_ error: any Error) {
    inbox.finish(.failure(Self.error(error)))
    channel.close(promise: nil)
  }

  @discardableResult
  func observed(_ frame: WebSocketFrame) -> Bool {
    if frame.opcode == .text || frame.opcode == .binary || frame.opcode == .continuation {
      let accepted = state.withLock { state -> Bool in
        let bytes = frame.unmaskedData.readableBytes
        if frame.opcode == .continuation && state.fragmentedBytes == nil { return true }
        let previous = frame.opcode == .continuation ? state.fragmentedBytes ?? 0 : 0
        guard bytes <= maxMessageBytes - min(previous, maxMessageBytes) else { return false }
        state.fragmentedBytes = frame.fin ? nil : previous + bytes
        return true
      }
      guard accepted else {
        inbox.finish(.failure(WebSocketError(kind: .messageTooLarge)))
        return false
      }
    }
    switch frame.opcode {
    case .connectionClose:
      var bytes = frame.unmaskedData
      let code = bytes.readInteger(as: UInt16.self).map(WebSocket.CloseCode.init(rawValue:))
      let reason =
        bytes.readableBytes == 0
        ? nil : String(bytes: bytes.readableBytesView, encoding: .utf8)
      state.withLock { state in state.close = WebSocketClose(code: code, reason: reason) }
    case .pong:
      var bytes = frame.unmaskedData
      guard let sequence: UInt64 = bytes.readInteger(), bytes.readableBytes == 0 else {
        return true
      }
      let ping = state.withLock { state -> WebSocketCompletion<Void>? in
        guard state.ping?.0 == sequence else { return nil }
        let ping = state.ping?.1
        state.ping = nil
        return ping
      }
      ping?.finish(.success(()))
    default: break
    }
    return true
  }

  func ping() async throws(WebSocketError) {
    let writer = try currentWriter()
    let completion = WebSocketCompletion<Void>()
    let sequence: UInt64 = try state.withLock { state throws(WebSocketError) in
      guard !state.failed else { throw WebSocketError(kind: .closed) }
      guard state.ping == nil else { throw WebSocketError(kind: .concurrentOperation) }
      state.sequence &+= 1
      state.ping = (state.sequence, completion)
      return state.sequence
    }
    var payload = ByteBuffer()
    payload.writeInteger(sequence)
    do {
      try await writer.write(
        .custom(.init(fin: true, opcode: .ping, data: payload)))
      try await completion.wait()
    } catch {
      state.withLock { state in
        if state.ping?.0 == sequence { state.ping = nil }
      }
      throw Self.error(error)
    }
  }

  func pump(_ inbound: WebSocketInboundStream, maxMessageBytes: Int) async {
    do {
      for try await message in inbound.messages(maxSize: maxMessageBytes) {
        let mapped: WebSocket.Message
        switch message {
        case .binary(let bytes): mapped = .binary(Data(bytes.readableBytesView))
        case .text(let text): mapped = .text(text)
        }
        guard inbox.offer(mapped) else { return }
      }
      if let close = closeInfo {
        inbox.finish(.success(close))
      } else {
        inbox.finish(.failure(WebSocketError(kind: .protocolViolation)))
      }
    } catch { inbox.finish(.failure(Self.error(error))) }
  }

  func receive() async throws(WebSocketError) -> WebSocket.Message? {
    try await inbox.next(reader: ObjectIdentifier(self))
  }

  func send(_ message: WebSocket.Message) async throws(WebSocketError) {
    let writer = try currentWriter()
    do {
      switch message {
      case .binary(let data):
        try await writer.writeBinaryMessage(ByteBuffer(bytes: data))
      case .text(let text):
        try await writer.writeTextMessage(text)
      }
    } catch { throw Self.error(error) }
  }
}

/// Passes every frame onward after observing only controls.
final class HummingbirdControlObserver: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame

  private let connection: HummingbirdWebSocketConnection

  init(connection: HummingbirdWebSocketConnection) { self.connection = connection }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if connection.observed(unwrapInboundIn(data)) { context.fireChannelRead(data) }
  }
}

/// Installed before Hummingbird unbuffers upgraded frames.
final class HummingbirdUpgradeObserver: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = NIOAny

  private let connection: HummingbirdWebSocketConnection

  init(connection: HummingbirdWebSocketConnection) { self.connection = connection }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if case HTTPServerUpgradeEvents.upgradeComplete = event {
      do {
        let decoder = try context.pipeline.syncOperations.context(
          handlerType: ByteToMessageHandler<WebSocketFrameDecoder>.self)
        try context.pipeline.syncOperations.addHandler(
          HummingbirdControlObserver(connection: connection), position: .after(decoder.handler))
        context.pipeline.syncOperations.removeHandler(self, promise: nil)
      } catch {
        connection.failedUpgrade(error)
      }
    }
    context.fireUserInboundEventTriggered(event)
  }
}

#endif
#endif
