// The observer writes through swift-log, which is fetched only when the `Logging` trait is enabled,
// so this file compiles to nothing without it.
#if Logging

import Logging

/// A ``TransportObserver`` that writes every event a client reports to a swift-log `Logger`.
///
/// Install one on an ``HTTPClient`` and each send appears in whatever logging backend the app
/// bootstrapped, with the request's shape and outcome as metadata: the attempt ordinal, whether a
/// credential was attached, the correlation identifier, the method, the target, the send's own
/// duration in whole milliseconds, the status, and, for a streamed body, how many bytes the reads
/// returned.
///
/// ```swift
/// import HTTPCore
/// import Logging
///
/// let client = HTTPClient(
///   baseURL: URL(string: "https://api.example.com/v1")!,
///   observer: LoggingObserver(logger: Logger(label: "com.example.api")),
///   transport: transport
/// )
///
/// let profile: Profile = try await client.execute(Request(path: "/me"))
/// ```
///
/// The logger is yours, so its label, its handler, and its own level are the app's decisions. The
/// observer never bootstraps one and never filters: it hands every event to the logger at that
/// event's level, and the logger's `logLevel` is what decides whether a line is emitted.
///
/// ## Levels
///
/// Each kind of event carries its own level, so the volume of one kind can be turned down without
/// losing another. The defaults suit a service whose logs are kept at `info`:
///
/// | Event | Property | Default |
/// |---|---|---|
/// | ``TransportObserver/willSend(_:)`` | ``requestLevel`` | `debug` |
/// | ``TransportObserver/didReceive(_:)`` | ``responseLevel`` | `info` |
/// | ``TransportObserver/didFail(_:)`` | ``failureLevel`` | `error` |
/// | ``TransportObserver/didFinishBody(_:)`` | ``bodyLevel`` | `debug` |
///
/// A status the client rejects is still a response, so a `500` is logged at ``responseLevel`` and
/// not at ``failureLevel``: only a send that produced no response at all reaches
/// ``TransportObserver/didFail(_:)``. Raise ``responseLevel`` if every status belongs in the same
/// stream as the failures, or write an observer of your own to split them by status.
///
/// ## What Is Never Logged
///
/// No line carries a credential, a header field, or a body byte. ``bodyPreviewLimit`` is left at
/// its default of `nil`, so no preview ever reaches this observer, and a
/// ``TransportError`` is written through its ``TransportError/description``, which reduces a status
/// failure to its code and body byte count rather than printing the body or the fields. The one
/// exception is a credential the request itself carries in its target, in the query string or the
/// userinfo: it appears in the target metadata, as it would in any other record of the request.
///
/// A description is text, never a format. It is interpolated into a `Logger.Message`, which
/// swift-log carries verbatim, so a server that answers with a percent sign or a brace in something
/// a transport quotes back cannot reach a backend's formatter through this observer.
public struct LoggingObserver: TransportObserver {
  /// The level a streamed body's end is logged at.
  ///
  /// One line arrives per body, whether it ended cleanly or in a failure, so the default is
  /// `debug`. A body that failed threw the same failure from the consumer's own read, where it is
  /// handled rather than only recorded.
  public var bodyLevel: Logger.Level

  /// The level a send that produced no response is logged at.
  ///
  /// The default is `error`. A retryable failure is reported once per attempt, so a request that
  /// eventually succeeds can still log more than one.
  public var failureLevel: Logger.Level

  /// The logger every event is written to.
  ///
  /// Assign a logger carrying metadata of its own to tag every line this observer writes, the way
  /// you would tag any other component's.
  public var logger: Logger

  /// The level a send is logged at before it goes out.
  ///
  /// The default is `debug`: the line arrives once per send and carries no outcome, so it is the
  /// highest volume and the least informative of the four.
  public var requestLevel: Logger.Level

  /// The level a response is logged at, whatever its status.
  ///
  /// The default is `info`, which makes this the line a service keeps in production.
  public var responseLevel: Logger.Level

  /// Creates an observer that writes to the logger you supply.
  ///
  /// The logger is required, because which subsystem a package's lines are filed under is the
  /// app's decision and not the package's.
  ///
  /// ```swift
  /// let observer = LoggingObserver(
  ///   logger: Logger(label: "com.example.api"),
  ///   responseLevel: .notice
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - bodyLevel: The level a streamed body's end is logged at; `debug` by default.
  ///   - failureLevel: The level a failed send is logged at; `error` by default.
  ///   - logger: The logger every event is written to.
  ///   - requestLevel: The level a send is logged at before it goes out; `debug` by default.
  ///   - responseLevel: The level a response is logged at; `info` by default.
  public init(
    bodyLevel: Logger.Level = .debug,
    failureLevel: Logger.Level = .error,
    logger: Logger,
    requestLevel: Logger.Level = .debug,
    responseLevel: Logger.Level = .info
  ) {
    self.bodyLevel = bodyLevel
    self.failureLevel = failureLevel
    self.logger = logger
    self.requestLevel = requestLevel
    self.responseLevel = responseLevel
  }

  /// Logs the failure at ``failureLevel``, with its description in the message.
  ///
  /// - Parameter event: What failed, and how long the send took.
  public func didFail(_ event: FailureEvent) {
    logger.log(
      level: failureLevel,
      "Send failed: \(event.failure)",
      metadata: [
        "attempt": .stringConvertible(event.attempt),
        "authAttached": .stringConvertible(event.authAttached),
        "correlationID": .string(event.correlationID),
        "durationMilliseconds": .stringConvertible(milliseconds(of: event.duration)),
        "method": .string(event.method.rawValue),
        "url": .stringConvertible(event.url),
      ]
    )
  }

  /// Logs the end of a streamed body at ``bodyLevel``, with the failure in the message when the
  /// body failed.
  ///
  /// The event carries no method, target, or timing, so the correlation identifier is what ties the
  /// line to the send that opened the body.
  ///
  /// - Parameter event: How many bytes were received, and what ended the body.
  public func didFinishBody(_ event: BodyEvent) {
    if let failure = event.failure {
      logger.log(
        level: bodyLevel,
        "Body failed: \(failure)",
        metadata: [
          "bytesReceived": .stringConvertible(event.bytesReceived),
          "correlationID": .string(event.correlationID),
        ]
      )
    } else {
      logger.log(
        level: bodyLevel,
        "Body ended",
        metadata: [
          "bytesReceived": .stringConvertible(event.bytesReceived),
          "correlationID": .string(event.correlationID),
        ]
      )
    }
  }

  /// Logs the response at ``responseLevel``, whatever its status.
  ///
  /// - Parameter event: The response's status, timing, and identifying detail.
  public func didReceive(_ event: ResponseEvent) {
    logger.log(
      level: responseLevel,
      "Received response",
      metadata: [
        "attempt": .stringConvertible(event.attempt),
        "authAttached": .stringConvertible(event.authAttached),
        "correlationID": .string(event.correlationID),
        "durationMilliseconds": .stringConvertible(milliseconds(of: event.duration)),
        "method": .string(event.method.rawValue),
        "status": .stringConvertible(event.status.code),
        "url": .stringConvertible(event.url),
      ]
    )
  }

  /// Logs the send at ``requestLevel``, before it goes out.
  ///
  /// - Parameter event: What is about to go on the wire.
  public func willSend(_ event: RequestEvent) {
    logger.log(
      level: requestLevel,
      "Sending request",
      metadata: [
        "attempt": .stringConvertible(event.attempt),
        "authAttached": .stringConvertible(event.authAttached),
        "correlationID": .string(event.correlationID),
        "method": .string(event.method.rawValue),
        "url": .stringConvertible(event.url),
      ]
    )
  }

  /// The whole milliseconds in `duration`, saturated at the ends of `Int` rather than trapping.
  ///
  /// A log line reports what a send took; a duration too large to count in milliseconds is worth a
  /// line at the boundary rather than a crash inside an observer.
  ///
  /// - Parameter duration: The duration to count.
  /// - Returns: The whole milliseconds in `duration`.
  private func milliseconds(of duration: Duration) -> Int {
    let components = duration.components
    let (scaled, scaledOverflowed) = components.seconds.multipliedReportingOverflow(by: 1000)
    let (total, totalOverflowed) = scaled.addingReportingOverflow(
      components.attoseconds / 1_000_000_000_000_000)
    guard !scaledOverflowed, !totalOverflowed else {
      return components.seconds < 0 ? Int.min : Int.max
    }
    return Int(clamping: total)
  }
}

#endif
