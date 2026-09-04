// `URLSession` and the loading system behind it exist only on Apple platforms, so this target
// compiles only where they do.
#if canImport(Darwin)

import Foundation
import HTTPCore
import HTTPTypes

extension HTTPClient {
  /// Creates a client that sends through `URLSession`.
  ///
  /// This is ``/HTTPCore/HTTPClient/init(authentication:baseURL:clock:correlationIDField:correlationIDGenerator:decoder:defaultHeaders:encoder:observer:redirectPolicy:retryPolicy:timeout:transport:)``
  /// with the transport built for you: a ``URLSessionTransport`` over `session`. Every other
  /// parameter carries the same default, so a client over the shared session takes one argument.
  ///
  /// ```swift
  /// import HTTPCore
  /// import HTTPURLSession
  ///
  /// let client = HTTPClient(baseURL: URL(string: "https://api.example.com/v1")!)
  /// ```
  ///
  /// - Parameters:
  ///   - authentication: The credential source and the rules around it; defaults to `nil`,
  ///     anonymous.
  ///   - baseURL: The base URL every request is resolved against.
  ///   - clock: The clock that times waits between attempts and measures each send; defaults to a
  ///     `ContinuousClock`.
  ///   - correlationIDField: The header field the correlation identifier is sent under; defaults to
  ///     `nil`, which sends none and leaves the identifier to the observer alone.
  ///   - correlationIDGenerator: Where each logical request's correlation identifier comes from;
  ///     defaults to a fresh UUID string.
  ///   - decoder: The decoder for typed responses; defaults to a plain `JSONDecoder()`.
  ///   - defaultHeaders: Header fields sent with every request; defaults to none.
  ///   - encoder: The encoder for JSON bodies; defaults to a plain `JSONEncoder()`.
  ///   - observer: The observer each send is reported to; defaults to `nil`, none.
  ///   - redirectPolicy: What the client does with a `3xx` that names a `Location`; defaults to
  ///     ``/HTTPCore/RedirectPolicy/follow``.
  ///   - retryPolicy: The client-wide retry policy; defaults to ``/HTTPCore/RetryPolicy/disabled``.
  ///   - session: The session every request goes through; defaults to `URLSession.shared`.
  ///   - timeout: The client-wide deadline for a whole request; defaults to `nil`, none.
  public init(
    authentication: Authentication? = nil,
    baseURL: URL,
    clock: any Clock<Duration> = ContinuousClock(),
    correlationIDField: HTTPField.Name? = nil,
    correlationIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
    decoder: JSONDecoder = JSONDecoder(),
    defaultHeaders: HTTPFields = [:],
    encoder: JSONEncoder = JSONEncoder(),
    observer: (any TransportObserver)? = nil,
    redirectPolicy: RedirectPolicy = .follow,
    retryPolicy: RetryPolicy = .disabled,
    session: URLSession = .shared,
    timeout: Duration? = nil
  ) {
    self.init(
      authentication: authentication,
      baseURL: baseURL,
      clock: clock,
      correlationIDField: correlationIDField,
      correlationIDGenerator: correlationIDGenerator,
      decoder: decoder,
      defaultHeaders: defaultHeaders,
      encoder: encoder,
      observer: observer,
      redirectPolicy: redirectPolicy,
      retryPolicy: retryPolicy,
      timeout: timeout,
      transport: URLSessionTransport(session: session)
    )
  }
}

#endif
