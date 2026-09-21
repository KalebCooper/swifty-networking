#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Opens explicitly owned WebSockets through an injected transport.
///
/// The client validates configuration before credentials or backend work. It shares request
/// validation, authentication replay and the whole-connect deadline across both conveniences.
public struct WebSocketClient: Sendable {
  private struct Backend: Sendable {
    let connection: any WebSocketConnection
  }

  private let clock: WebSocketClock
  private let transport: any WebSocketTransport

  /// Creates a client using an injectable clock, defaulting to ContinuousClock.
  public init<C: Clock>(clock: C = ContinuousClock(), transport: any WebSocketTransport)
  where C.Duration == Duration {
    self.clock = WebSocketClock(clock)
    self.transport = transport
  }

  /// Opens a connection with a bounded inbox and captured options.
  ///
  /// Invalid configuration throws invalidRequest before backend or credential work.
  /// Cancellation and timeout discard any late successful connection.
  public func connect(_ request: WebSocketRequest, options: WebSocket.Options = .init())
    async throws(WebSocketError) -> WebSocket
  {
    guard !Task.isCancelled else { throw WebSocketError(kind: .cancelled) }
    try options.validate()
    let backend = try await WebSocketHandshake.connect(
      request, clock: clock, discard: { $0.connection.cancel() },
      timeout: options.connectTimeout
    ) { (request) throws(WebSocketError) in
      let connection = try await transport.connect(request, options: options)
      return Backend(connection: connection)
    }
    return WebSocket(
      session: WebSocketSession(backend: backend.connection, clock: clock, options: options))
  }

  /// Opens a URL using the same execution as a WebSocketRequest.
  public func connect(to url: URL, options: WebSocket.Options = .init())
    async throws(WebSocketError) -> WebSocket
  {
    try await connect(WebSocketRequest(url: url), options: options)
  }

  /// Returns the operation's result and aborts the connection on every scope exit.
  ///
  /// The closure and result need not be Sendable. An escaped handle is terminal after this
  /// returns. Cancellation aborts backend work promptly; arbitrary application code remains
  /// responsible for cooperating with cancellation. Application errors are preserved.
  /// The operation parameter follows options to support trailing-closure syntax.
  public func withConnection<Value>(
    _ request: WebSocketRequest,
    isolation: isolated (any Actor)? = #isolation,
    options: WebSocket.Options = .init(),
    operation: (WebSocket) async throws -> Value
  ) async throws -> Value {
    let socket = try await connect(request, options: options)
    defer { socket.cancel() }
    return try await withTaskCancellationHandler {
      try await operation(socket)
    } onCancel: {
      socket.cancel()
    }
  }

  /// Scopes a URL connection, returning the operation's result with automatic cleanup.
  public func withConnection<Value>(
    to url: URL,
    isolation: isolated (any Actor)? = #isolation,
    options: WebSocket.Options = .init(),
    operation: (WebSocket) async throws -> Value
  ) async throws -> Value {
    try await withConnection(
      WebSocketRequest(url: url), isolation: isolation, options: options, operation: operation)
  }
}
