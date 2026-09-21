#if canImport(Darwin)
import Foundation
import WebSocketCore

/// Opens WebSockets using an owned URLSession with system server-trust validation.
///
/// Use this transport through WebSocketClient for request validation, authentication and deadlines.
/// Redirects are refused. Cookies and credentials are never loaded from shared storage.
/// Connections share the transport's session, but cancelling one does not stop another.
///
/// ```swift
/// let client = WebSocketClient(transport: URLSessionWebSocketTransport())
/// let socket = try await client.connect(to: endpoint)
/// try await socket.send("subscribe")
/// ```
public struct URLSessionWebSocketTransport: WebSocketTransport {
  let session = URLSessionWebSocketSession()

  /// Creates an independent session without automatic cookie or credential storage.
  public init() {}

  /// Starts a connection attempt and returns after protocol negotiation.
  ///
  /// The request must have no Authentication value; WebSocketClient renders credentials first.
  /// Cancellation aborts the physical task. Failure preserves available HTTP response metadata.
  public func connect(_ request: WebSocketRequest, options: WebSocket.Options)
    async throws(WebSocketError) -> some WebSocketConnection
  {
    guard !Task.isCancelled else { throw WebSocketError(kind: .cancelled) }
    try request.validate()
    guard request.authentication == nil, options.maxMessageBytes > 0 else {
      throw WebSocketError(kind: .invalidRequest)
    }
    var urlRequest = URLRequest(url: request.url)
    for field in request.headers {
      urlRequest.addValue(field.value, forHTTPHeaderField: field.name.rawName)
    }
    if !request.subprotocols.isEmpty {
      urlRequest.setValue(
        request.subprotocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
    }
    let task = session.session.webSocketTask(with: urlRequest)
    task.maximumMessageSize = options.maxMessageBytes
    let exchange = URLSessionWebSocketExchange(protocols: request.subprotocols, task: task)
    session.delegate.insert(exchange, for: task)
    let result: Result<Void, WebSocketError> = await withTaskCancellationHandler {
      task.resume()
      do throws(WebSocketError) {
        try await exchange.opening.wait()
        return .success(())
      } catch {
        return .failure(error)
      }
    } onCancel: {
      exchange.cancel()
    }
    guard !Task.isCancelled else {
      exchange.cancel()
      throw WebSocketError(kind: .cancelled)
    }
    do throws(WebSocketError) {
      try result.get()
    } catch {
      exchange.cancel()
      throw error
    }
    return BackendConnection(exchange: exchange, session: session)
  }

  private final class BackendConnection: WebSocketConnection {
    private let exchange: URLSessionWebSocketExchange
    private let session: URLSessionWebSocketSession

    init(exchange: URLSessionWebSocketExchange, session: URLSessionWebSocketSession) {
      self.exchange = exchange
      self.session = session
    }

    deinit { exchange.cancel() }

    var closeInfo: WebSocketClose? { exchange.closeInfo }
    var negotiatedSubprotocol: String? { exchange.negotiatedSubprotocol }

    func cancel() { exchange.cancel() }

    func close(code: WebSocket.CloseCode, reason: String?)
      async throws(WebSocketError) -> WebSocketClose
    {
      try await exchange.close(code: code, reason: reason)
    }

    func ping() async throws(WebSocketError) { try await exchange.ping() }

    func receive() async throws(WebSocketError) -> WebSocket.Message? {
      try await exchange.receive()
    }

    func send(_ message: WebSocket.Message) async throws(WebSocketError) {
      try await exchange.send(message)
    }
  }
}
#endif
