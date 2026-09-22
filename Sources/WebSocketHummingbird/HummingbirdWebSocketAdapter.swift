#if WebSocketHummingbird
#if os(Linux) || os(macOS)
import HummingbirdWebSocket
import NIOCore
import WebSocketCore
import WSCore

/// Adapts accepted Hummingbird upgrades to the shared WebSocket connection API.
///
/// Install `configuration` on Hummingbird's server builder and call `prepare(channel:)`
/// inside its upgrade decision, after the application's authentication checks. Hummingbird
/// retains ownership of its listener, channel and event loops.
public struct HummingbirdWebSocketAdapter: Sendable {
  private let options: WebSocket.Options

  /// Validates the options captured by every accepted connection.
  public init(options: WebSocket.Options = .init()) throws(WebSocketError) {
    try options.validate()
    self.options = options
  }

  /// Upstream frame and control settings required by the common connection contract.
  ///
  /// Use this value as the builder's `ws` configuration. Its frame limit bounds
  /// allocation before message assembly; the shared inbox enforces maxMessageBytes.
  /// Hummingbird's automatic heartbeat is disabled so ping has one correlated policy.
  public var configuration: WebSocketServerConfiguration {
    .init(
      maxFrameSize: max(125, min(options.maxMessageBytes, 16_384)),
      autoPing: .disabled,
      closeTimeout: options.closeTimeout,
      validateUTF8: true)
  }

  /// Installs the public NIO upgrade-event observer before buffered frames are released.
  ///
  /// Call this from Hummingbird's `shouldUpgrade` closure only for an authorized request.
  /// The returned scope belongs to this accepted channel and may run once.
  public func prepare(
    channel: any Channel, negotiatedSubprotocol: String? = nil
  ) async throws(WebSocketError) -> HummingbirdWebSocketScope {
    let connection = HummingbirdWebSocketConnection(
      channel: channel, options: options, protocolName: negotiatedSubprotocol)
    do {
      try await channel.eventLoop.submit {
        try channel.pipeline.syncOperations.addHandler(
          HummingbirdUpgradeObserver(connection: connection))
      }.get()
    } catch {
      connection.cancel()
      throw WebSocketError(kind: .transport, underlying: error)
    }
    return HummingbirdWebSocketScope(connection: connection, options: options)
  }
}

/// A single accepted Hummingbird handler scope.
///
/// Returning or throwing from `withConnection` aborts the borrowed channel and settles
/// pending operations. A socket retained beyond that scope is closed.
public final class HummingbirdWebSocketScope: Sendable {
  private let connection: HummingbirdWebSocketConnection
  private let options: WebSocket.Options

  init(connection: HummingbirdWebSocketConnection, options: WebSocket.Options) {
    self.connection = connection
    self.options = options
  }

  /// Runs application code with the same bounded inbox and send queue as client sockets.
  ///
  /// The physical reader keeps running while an application message waiter is cancelled.
  /// Application code should process messages sequentially when its domain requires order.
  /// Cancellation of the Hummingbird handler aborts only this channel.
  public func withConnection<Value>(
    inbound: WebSocketInboundStream,
    outbound: WebSocketOutboundWriter,
    isolation: isolated (any Actor)? = #isolation,
    operation: (WebSocket) async throws -> Value
  ) async throws -> Value {
    try connection.attach(outbound)
    let socket = try WebSocket.accepted(connection, options: options)
    let reader = Task { await connection.pump(inbound, maxMessageBytes: options.maxMessageBytes) }
    do {
      let value = try await withTaskCancellationHandler {
        try await operation(socket)
      } onCancel: {
        socket.cancel()
      }
      socket.cancel()
      await reader.value
      return value
    } catch {
      socket.cancel()
      await reader.value
      throw error
    }
  }
}
#endif
#endif
