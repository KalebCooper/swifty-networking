#if WebSocketPortable
import HTTPCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import Synchronization
import WebSocketCore

/// A WebSocket client transport with an owned event-loop group and TLS context.
///
/// Use through WebSocketClient for authentication, deadlines and shared session policies.
/// TLS verifies the server certificate and hostname using NIOSSL's default trust roots.
/// Call shutdown() when the transport is no longer needed. Cancelling one socket leaves other
/// connections usable; shutting down the transport terminates all of them.
public final class NIOWebSocketTransport: WebSocketTransport {
  private struct State {
    var connections: [ObjectIdentifier: NIOWebSocketExchange] = [:]
    var shutdown: WebSocketCompletion<Void>?
  }

  private let context: NIOSSLContext
  private let group: MultiThreadedEventLoopGroup
  private let keySource: @Sendable () -> String
  private let state = Mutex(State())

  /// Creates reusable transport resources using the platform's default trust roots.
  public convenience init() throws(WebSocketError) {
    do {
      try self.init(configuration: .makeClientConfiguration())
    } catch { throw NIOWebSocketExchange.error(error) }
  }

  // Only test fixtures can supply a private CA; no production verification bypass is exposed.
  init(
    configuration: TLSConfiguration,
    keySource: @escaping @Sendable () -> String = { NIOWebSocketClientUpgrader.randomRequestKey() }
  ) throws {
    self.keySource = keySource
    context = try NIOSSLContext(configuration: configuration)
    group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  }

  deinit { _ = beginShutdown() }

  var channels: [any Channel] { state.withLock { $0.connections.values.compactMap(\.channel) } }
  var connectionCount: Int { state.withLock { $0.connections.count } }

  /// Performs one HTTP upgrade without redirects or hidden reconnect attempts.
  ///
  /// The request must already contain rendered credentials. Use WebSocketClient to validate
  /// configuration and enforce its single connect deadline across DNS, TCP, TLS and upgrade.
  public func connect(_ request: WebSocketRequest, options: WebSocket.Options)
    async throws(WebSocketError) -> some WebSocketConnection
  {
    guard !Task.isCancelled else { throw WebSocketError(kind: .cancelled) }
    try request.validate()
    guard request.authentication == nil, options.maxMessageBytes > 0,
      options.maxBufferedMessages > 0, options.maxBufferedBytes >= options.maxMessageBytes,
      let authority = URLReference.parse(request.url.absoluteString).authority,
      let host = request.url.host(percentEncoded: false)
    else { throw WebSocketError(kind: .invalidRequest) }
    let exchange = NIOWebSocketExchange(options: options)
    let admitted = state.withLock { state in
      guard state.shutdown == nil else { return false }
      state.connections[ObjectIdentifier(exchange)] = exchange
      return true
    }
    guard admitted else { throw WebSocketError(kind: .closed) }
    let secure = request.url.scheme?.lowercased() == "wss"
    let parts = URLReference.parse(request.url.absoluteString)
    let target = (parts.path.isEmpty ? "/" : parts.path) + (parts.query.map { "?" + $0 } ?? "")
    let context = self.context
    let requestKey = keySource()
    let bootstrap = ClientBootstrap(group: group).channelInitializer { channel in
      exchange.register(channel)
      return channel.eventLoop.makeCompletedFuture {
        if secure {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSLClientHandler(context: context, serverHostname: host))
        }
        let headLimit = NIOWebSocketHeadLimit(exchange: exchange)
        let encoder = HTTPRequestEncoder()
        var limits = NIOHTTPDecoderLimitConfiguration()
        limits.maxHeaderFieldCount = 100
        limits.maxHeaderFieldSize = 16_384
        limits.maxHeaderListSize = 16_384
        let decoder = ByteToMessageHandler(
          HTTPResponseDecoder(
            leftOverBytesStrategy: .forwardBytes, informationalResponseStrategy: .forward,
            limitConfiguration: limits))
        let handshake = NIOWebSocketHandshake(exchange: exchange, protocols: request.subprotocols)
        let upgrader = NIOWebSocketClientUpgrader(
          requestKey: requestKey,
          maxFrameSize: min(max(options.maxMessageBytes, 125), Int(UInt32.max)),
          automaticErrorHandling: false
        ) { channel, response in
          channel.eventLoop.makeCompletedFuture {
            let decoder = try channel.pipeline.syncOperations.handler(
              type: ByteToMessageHandler<WebSocketFrameDecoder>.self)
            try channel.pipeline.syncOperations.addHandler(
              NIOWebSocketFrameValidation(exchange: exchange), position: .before(decoder))
            try channel.pipeline.syncOperations.addHandler(
              NIOWebSocketHandler(exchange: exchange, maximum: options.maxMessageBytes))
            exchange.opened(protocolName: response.headers.first(name: "sec-websocket-protocol"))
          }
        }
        let upgrade = NIOHTTPClientUpgradeHandler(
          upgraders: [upgrader], httpHandlers: [headLimit, encoder, decoder, handshake],
          upgradeCompletionHandler: { _ in })
        try channel.pipeline.syncOperations.addHandlers(
          headLimit, encoder, decoder, handshake, upgrade)
        try channel.pipeline.syncOperations.addHandler(
          NIOWebSocketFailureHandler(exchange: exchange))
      }
    }
    let result: Result<Void, WebSocketError> = await withTaskCancellationHandler {
      bootstrap.connect(host: host, port: request.url.port ?? (secure ? 443 : 80)).whenComplete {
        result in
        switch result {
        case .failure(let error):
          exchange.fail(NIOWebSocketExchange.error(error))
          self.release(exchange)
        case .success(let channel):
          exchange.attach(channel)
          channel.closeFuture.whenComplete { _ in self.release(exchange) }
          var headers = HTTPHeaders([("Host", authority)])
          for field in request.headers { headers.add(name: field.name.rawName, value: field.value) }
          if !request.subprotocols.isEmpty {
            headers.add(
              name: "Sec-WebSocket-Protocol", value: request.subprotocols.joined(separator: ", "))
          }
          let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: target, headers: headers)
          channel.write(HTTPClientRequestPart.head(head), promise: nil)
          channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure {
            exchange.fail(NIOWebSocketExchange.error($0))
          }
        }
      }
      do throws(WebSocketError) { return .success(try await exchange.opening.wait()) } catch {
        return .failure(error)
      }
    } onCancel: {
      exchange.cancel()
    }
    guard !Task.isCancelled else { exchange.cancel(); throw WebSocketError(kind: .cancelled) }
    try result.get()
    return BackendConnection(exchange: exchange, transport: self)
  }

  /// Refuses new connects, aborts pending and open connections, and releases the owned group.
  ///
  /// Concurrent and repeated callers share one shutdown. Cancelling a waiter does not interrupt
  /// resource cleanup; another call can await its completion.
  public func shutdown() async throws(WebSocketError) {
    try await beginShutdown().wait()
  }

  private func beginShutdown() -> WebSocketCompletion<Void> {
    let completion = WebSocketCompletion<Void>()
    let result = state.withLock { state -> (WebSocketCompletion<Void>, [NIOWebSocketExchange]?) in
      if let existing = state.shutdown { return (existing, nil) }
      state.shutdown = completion
      return (completion, Array(state.connections.values))
    }
    if let connections = result.1 {
      for connection in connections { connection.cancel() }
      let group = self.group
      Task {
        do {
          for connection in connections { try await connection.released.wait() }
          try await group.shutdownGracefully()
          completion.finish(.success(()))
        } catch { completion.finish(.failure(NIOWebSocketExchange.error(error))) }
      }
    }
    return result.0
  }

  private func release(_ exchange: NIOWebSocketExchange) {
    _ = state.withLock { $0.connections.removeValue(forKey: ObjectIdentifier(exchange)) }
    exchange.released.finish(.success(()))
  }

  private final class BackendConnection: WebSocketBufferedConnection {
    let exchange: NIOWebSocketExchange
    let transport: NIOWebSocketTransport

    init(exchange: NIOWebSocketExchange, transport: NIOWebSocketTransport) {
      self.exchange = exchange
      self.transport = transport
    }

    deinit { exchange.cancel() }

    var closeInfo: WebSocketClose? { exchange.closeInfo }
    var inbox: WebSocketInbox { exchange.inbox }
    var negotiatedSubprotocol: String? { exchange.negotiatedSubprotocol }

    func cancel() { exchange.cancel() }
    func close(code: WebSocket.CloseCode, reason: String?) async throws(WebSocketError)
      -> WebSocketClose
    {
      try await exchange.close(code: code, reason: reason)
    }
    func ping() async throws(WebSocketError) { try await exchange.ping() }
    func receive() async throws(WebSocketError) -> WebSocket.Message? {
      try await inbox.next(reader: ObjectIdentifier(self))
    }
    func send(_ message: WebSocket.Message) async throws(WebSocketError) {
      try await exchange.send(message)
    }
  }
}
#endif
