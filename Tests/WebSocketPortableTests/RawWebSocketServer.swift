#if WebSocketPortable
import NIOCore
import NIOPosix
import NIOSSL
import Synchronization
import WebSocketCore

/// A scripted byte peer with bounded capture and explicit channel teardown.
final class RawWebSocketServer: Sendable {
  static let upgrade =
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"

  let accepted = WebSocketCompletion<any Channel>()
  let closed = WebSocketCompletion<Void>()
  let frames: AsyncStream<[UInt8]>
  private let frameSignal: AsyncStream<[UInt8]>.Continuation
  let head = WebSocketCompletion<String>()
  private let peers = Mutex<[any Channel]>([])
  let prefix = WebSocketCompletion<[UInt8]>()
  private let received = Mutex<[UInt8]>([])
  private let running = Mutex<(any Channel)?>(nil)

  init() { (frames, frameSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(16)) }

  var bytes: [UInt8] { received.withLock { $0 } }
  var port: Int { running.withLock { $0?.localAddress?.port ?? 0 } }

  func start(
    initial: [UInt8] = [], response: String? = RawWebSocketServer.upgrade, tls: Bool = false
  ) async throws {
    let context = try tls ? TLSFixture.serverContext.get() : nil
    let channel = try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        self.peers.withLock { $0.append(channel) }
        self.accepted.finish(.success(channel))
        channel.closeFuture.whenComplete { _ in self.closed.finish(.success(())) }
        return channel.eventLoop.makeCompletedFuture {
          if let context {
            try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
          }
          try channel.pipeline.syncOperations.addHandler(
            Handler(initial: initial, response: response, server: self))
        }
      }.bind(host: "127.0.0.1", port: 0).get()
    running.withLock { $0 = channel }
  }

  func stop() async throws {
    let listener = running.withLock { state in
      let channel = state; state = nil; return channel
    }
    try await listener?.close().get()
    let channels = peers.withLock { state in
      let channels = state; state.removeAll(); return channels
    }
    for channel in channels {
      try? await channel.close().get()
      try await channel.closeFuture.get()
    }
    frameSignal.finish()
  }

  private final class Handler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var buffer: [UInt8] = []
    private var frameBytes: [UInt8] = []
    private var handshake = false
    private let initial: [UInt8]
    private let response: String?
    private let server: RawWebSocketServer

    init(initial: [UInt8], response: String?, server: RawWebSocketServer) {
      self.initial = initial
      self.response = response
      self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      buffer += unwrapInboundIn(data).readableBytesView
      guard buffer.count <= 65_536 else { context.close(promise: nil); return }
      if !handshake {
        guard
          let end = (0..<max(0, buffer.count - 3)).first(where: {
            Array(buffer[$0..<($0 + 4)]) == [13, 10, 13, 10]
          })
        else { return }
        let head = String(decoding: buffer.prefix(end + 4), as: UTF8.self)
        buffer.removeFirst(end + 4)
        handshake = true
        server.head.finish(.success(head))
        if let response {
          context.writeAndFlush(
            wrapOutboundOut(ByteBuffer(bytes: Array(response.utf8) + initial)), promise: nil)
        }
      }
      if !buffer.isEmpty {
        server.received.withLock { bytes in
          if bytes.count + buffer.count <= 65_536 { bytes += buffer }
        }
        let captured = server.bytes
        if captured.count >= 8 { server.prefix.finish(.success(captured)) }
        frameBytes += buffer
        buffer.removeAll()
        while frameBytes.count >= 6 {
          let length = Int(frameBytes[1] & 0x7F)
          guard length < 126, frameBytes[1] & 0x80 != 0,
            frameBytes.count >= length + 6
          else { return }
          let frame = Array(frameBytes.prefix(length + 6))
          frameBytes.removeFirst(length + 6)
          if case .dropped = server.frameSignal.yield(frame) { context.close(promise: nil) }
        }
      }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
      context.close(promise: nil)
    }
  }
}
#endif
