#if canImport(Darwin)
import Foundation
import HTTPTypes
import HTTPTypesFoundation
import Synchronization
import WebSocketCore

/// Routes callbacks only to registered task identities and releases entries at task completion.
final class URLSessionWebSocketDelegate: NSObject, Foundation.URLSessionWebSocketDelegate {
  let invalidation = WebSocketCompletion<Void>()
  private let registry = Mutex<[ObjectIdentifier: URLSessionWebSocketExchange]>([:])

  var activeConnectionCount: Int { registry.withLock { $0.count } }

  func insert(_ exchange: URLSessionWebSocketExchange, for task: URLSessionWebSocketTask) {
    registry.withLock { $0[ObjectIdentifier(task)] = exchange }
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
    let exchanges = registry.withLock { registry in
      let exchanges = Array(registry.values)
      registry.removeAll()
      return exchanges
    }
    for exchange in exchanges { exchange.cancel() }
    invalidation.finish(.success(()))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let exchange = registry.withLock { $0.removeValue(forKey: ObjectIdentifier(task)) }
    exchange?.complete(error: error, response: (task.response as? HTTPURLResponse)?.httpResponse)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      // Credentials are explicit request headers; Foundation must not replay a challenge itself.
      let exchange = registry.withLock { $0[ObjectIdentifier(task)] }
      exchange?.reject(response: (challenge.failureResponse as? HTTPURLResponse)?.httpResponse)
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let exchange = registry.withLock { $0[ObjectIdentifier(task)] }
    exchange?.reject(response: response.httpResponse)
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    let exchange = registry.withLock { $0[ObjectIdentifier(webSocketTask)] }
    exchange?.recordClose(code: closeCode, reason: reason)
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    let exchange = registry.withLock { $0[ObjectIdentifier(webSocketTask)] }
    exchange?.open(protocol: `protocol`)
  }
}

/// The transport and returned connections own this lifetime; callbacks never retain it.
final class URLSessionWebSocketSession: Sendable {
  let delegate: URLSessionWebSocketDelegate
  let session: URLSession

  init() {
    delegate = URLSessionWebSocketDelegate()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = .greatestFiniteMagnitude
    configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }
}
#endif
