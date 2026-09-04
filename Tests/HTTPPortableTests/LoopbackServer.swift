// The server answers the AsyncHTTPClient transport, which exists only behind the `HTTPPortable`
// trait, so it compiles only where the transport does.
#if HTTPPortable

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

/// What the server puts on the wire for one request. It decides nothing: a test hands it the whole
/// answer, and the handler replays it.
enum Answer: Sendable {
  /// No response and no connection: the request is recorded and the connection closed, so the
  /// client sees the connection go away before any status arrives.
  case close

  /// A response whose body never ends, sent as soon as the request head arrives: the head, then
  /// `chunk` again and again until the connection closes. What a server does when a client keeps
  /// reading, so a test can prove what happens when the client stops.
  case endless(chunk: Data)

  /// No response at all: the request is recorded and the connection left open, so a caller stays
  /// parked until it is cancelled or its client times out.
  case hang

  /// A complete response: the head, each chunk written and flushed on its own, then the end of
  /// the response, or, with `closeAfterChunks`, the connection closed instead of the end, so the
  /// client sees the body cut short.
  case response(
    chunks: [Data] = [], closeAfterChunks: Bool = false, headers: [(String, String)] = [],
    status: Int)
}

/// One request as the server received it, complete.
struct RecordedRequest: Sendable {
  let body: Data
  let headers: HTTPHeaders
  let method: String
  let uri: String

  /// The first value of the named header field, or `nil`.
  func header(_ name: String) -> String? {
    headers.first(name: name)
  }
}

/// The answers a server gives and the requests it saw, shared by every connection it accepts.
///
/// Answers come from a FIFO queue or from a handler that sees the request head; a request neither
/// covers is answered `500`, so a test that scripted too little fails as a test instead of hanging.
final class Script: Sendable {
  private struct State {
    var answers: [Answer]
    var handler: (@Sendable (HTTPRequestHead) -> Answer)?
    var requests: [RecordedRequest] = []
  }

  /// Arrived at once per request the server has received to its end.
  let arrived = Latch()

  /// Arrived at once per connection the server has seen close.
  let closed = Latch()

  /// Arrived at once per connection the server has accepted.
  let opened = Latch()

  private let state: Mutex<State>

  /// A script that answers from `answers` in order.
  init(answers: [Answer] = []) {
    state = Mutex(State(answers: answers, handler: nil))
  }

  /// A script that answers every request through `handler`.
  init(handler: @escaping @Sendable (HTTPRequestHead) -> Answer) {
    state = Mutex(State(answers: [], handler: handler))
  }

  /// Every request received to its end, in arrival order.
  var requests: [RecordedRequest] {
    state.withLock { $0.requests }
  }

  /// The most recent request received to its end.
  var last: RecordedRequest? {
    state.withLock { $0.requests.last }
  }

  /// The answer for a request whose head has arrived.
  fileprivate func answer(for head: HTTPRequestHead) -> Answer {
    state.withLock { state in
      if let handler = state.handler {
        return handler(head)
      }
      if state.answers.isEmpty {
        return .response(status: 500)
      }
      return state.answers.removeFirst()
    }
  }

  fileprivate func record(_ request: RecordedRequest) {
    state.withLock { $0.requests.append(request) }
    arrived.arrive()
  }
}

/// An HTTP/1.1 server on a loopback port the transport under test sends to.
///
/// Every connection runs the same script. The server channel is closed by ``stop()``; the
/// connections it accepted close when the client closes them, which the transport's shutdown does.
final class LoopbackServer: Sendable {
  /// The `host:port` a request names to reach this server.
  let authority: String

  /// The script every connection answers from.
  let script: Script

  private let channel: any Channel

  private init(channel: any Channel, port: Int, script: Script) {
    authority = "127.0.0.1:\(port)"
    self.channel = channel
    self.script = script
  }

  /// Binds a server on a free loopback port.
  static func start(_ script: Script) async throws -> LoopbackServer {
    let channel = try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.configureHTTPServerPipeline()
          try channel.pipeline.syncOperations.addHandler(Handler(script: script))
        }
      }
      .bind(host: "127.0.0.1", port: 0)
      .get()
    guard let port = channel.localAddress?.port else {
      throw LoopbackServerFailure.noPort
    }
    return LoopbackServer(channel: channel, port: port, script: script)
  }

  /// Stops accepting connections.
  func stop() async throws {
    try await channel.close().get()
  }
}

/// The one way starting a server fails that the bootstrap does not report itself.
enum LoopbackServerFailure: Error {
  case noPort
}

/// One connection's half of the script: records the request, replays the answer.
private final class Handler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private var answer: Answer?
  private var body = Data()
  private var head: HTTPRequestHead?
  private let script: Script

  init(script: Script) {
    self.script = script
  }

  func channelActive(context: ChannelHandlerContext) {
    script.opened.arrive()
    context.fireChannelActive()
  }

  func channelInactive(context: ChannelHandlerContext) {
    script.closed.arrive()
    context.fireChannelInactive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let requestHead):
      head = requestHead
      body = Data()
      let answer = script.answer(for: requestHead)
      self.answer = answer
      if case .endless(let chunk) = answer {
        context.write(
          wrapOutboundOut(.head(Self.responseHead(headers: [], status: 200))), promise: nil)
        pump(chunk, context: context)
      }
    case .body(let buffer):
      body.append(Data(buffer: buffer))
    case .end:
      guard let head, let answer else { return }
      script.record(
        RecordedRequest(
          body: body, headers: head.headers, method: head.method.rawValue, uri: head.uri))
      write(answer, context: context)
    }
  }

  /// Writes a complete answer, or closes the connection for a close; an endless one was written at
  /// the head, and a hang writes nothing.
  private func write(_ answer: Answer, context: ChannelHandlerContext) {
    if case .close = answer {
      context.close(promise: nil)
      return
    }
    guard case .response(let chunks, let closeAfterChunks, let headers, let status) = answer else {
      return
    }
    context.write(
      wrapOutboundOut(.head(Self.responseHead(headers: headers, status: status))), promise: nil)
    for chunk in chunks {
      context.writeAndFlush(
        wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: chunk)))), promise: nil)
    }
    if closeAfterChunks {
      context.close(promise: nil)
    } else {
      context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
  }

  /// Writes `chunk`, and writes it again once that write has reached the socket, until the
  /// connection closes. Each round is queued on the loop rather than recursed, so the loop serves
  /// its other channels between chunks.
  private func pump(_ chunk: Data, context: ChannelHandlerContext) {
    guard context.channel.isActive else { return }
    let loop = context.eventLoop
    let handler = NIOLoopBound(self, eventLoop: loop)
    let boundContext = NIOLoopBound(context, eventLoop: loop)
    let promise = loop.makePromise(of: Void.self)
    promise.futureResult.whenSuccess { _ in
      loop.execute {
        handler.value.pump(chunk, context: boundContext.value)
      }
    }
    context.writeAndFlush(
      wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: chunk)))), promise: promise)
  }

  private static func responseHead(headers: [(String, String)], status: Int) -> HTTPResponseHead {
    HTTPResponseHead(
      version: .http1_1, status: HTTPResponseStatus(statusCode: status),
      headers: HTTPHeaders(headers))
  }
}

#endif
