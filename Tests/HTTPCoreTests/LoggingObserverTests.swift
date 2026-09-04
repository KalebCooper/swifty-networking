// The observer under test exists only with the `Logging` trait enabled, so its suite compiles where
// it does and nowhere else.
#if Logging

import HTTPCore
import HTTPTesting
import HTTPTypes
import Logging
import Synchronization
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// One line a handler was asked to emit, kept as the text a backend would write.
private struct Line: Sendable {
  var level: Logger.Level
  var message: String
  var metadata: [String: String]
}

/// The lines a logger's handlers emitted, in the order they arrived.
///
/// A `Logger` copies its handler, so the store the handlers append to is a reference held beside
/// them rather than state inside one.
private final class Capture: Sendable {
  private let lines = Mutex<[Line]>([])

  var all: [Line] { lines.withLock { $0 } }

  var only: Line? { lines.withLock { $0.count == 1 ? $0.first : nil } }

  func append(_ line: Line) {
    lines.withLock { $0.append(line) }
  }
}

/// A `LogHandler` that records what it was asked to emit and decides nothing.
private struct CapturingHandler: LogHandler {
  let capture: Capture
  var logLevel: Logger.Level = .trace
  var metadata: Logger.Metadata = [:]
  var metadataProvider: Logger.MetadataProvider?

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    capture.append(
      Line(
        level: event.level,
        message: event.message.description,
        metadata: (event.metadata ?? [:]).mapValues { $0.description }
      )
    )
  }
}

/// An error whose description reads like a format string.
private struct FormatShapedError: Error, CustomStringConvertible {
  var description: String { "%@ %s %d {0} %n" }
}

private let correlationID = "8b1f"
private let url = URL.fixture("https://example.com/a")

/// An observer writing to a fresh capture, with the levels it is given.
private func observed(
  bodyLevel: Logger.Level = .debug,
  failureLevel: Logger.Level = .error,
  handlerLevel: Logger.Level = .trace,
  requestLevel: Logger.Level = .debug,
  responseLevel: Logger.Level = .info
) -> (capture: Capture, observer: LoggingObserver) {
  let capture = Capture()
  let logger = Logger(label: "test") { _ in
    var handler = CapturingHandler(capture: capture)
    handler.logLevel = handlerLevel
    return handler
  }
  return (
    capture,
    LoggingObserver(
      bodyLevel: bodyLevel,
      failureLevel: failureLevel,
      logger: logger,
      requestLevel: requestLevel,
      responseLevel: responseLevel
    )
  )
}

private func bodyEnd(bytes: Int, failure: TransportError? = nil) -> BodyEvent {
  BodyEvent(bytesReceived: bytes, correlationID: correlationID, failure: failure)
}

private func failure(_ error: TransportError) -> FailureEvent {
  FailureEvent(
    attempt: 2, authAttached: false, correlationID: correlationID, duration: .milliseconds(25),
    failure: error, method: .post, url: url)
}

private func request() -> RequestEvent {
  RequestEvent(
    attempt: 1, authAttached: true, correlationID: correlationID, method: .get, url: url)
}

private func response(status: HTTPResponse.Status) -> ResponseEvent {
  ResponseEvent(
    attempt: 1, authAttached: true, correlationID: correlationID, duration: .milliseconds(10),
    method: .get, status: status, url: url)
}

@Suite("LoggingObserver", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct LoggingObserverTests {
  static let levels: [Logger.Level] = [.trace, .notice, .warning, .critical]

  @Test("A send is logged at the request level with its method, target, attempt, and credential")
  func requestCarriesTheSendsShape() {
    let (capture, observer) = observed()
    observer.willSend(request())
    #expect(capture.only?.level == .debug)
    #expect(capture.only?.message == "Sending request")
    #expect(
      capture.only?.metadata == [
        "attempt": "1",
        "authAttached": "true",
        "correlationID": "8b1f",
        "method": "GET",
        "url": "https://example.com/a",
      ])
  }

  @Test("A response is logged at the response level with its status and its own duration")
  func responseCarriesTheStatusAndDuration() {
    let (capture, observer) = observed()
    observer.didReceive(response(status: .ok))
    #expect(capture.only?.level == .info)
    #expect(capture.only?.message == "Received response")
    #expect(
      capture.only?.metadata == [
        "attempt": "1",
        "authAttached": "true",
        "correlationID": "8b1f",
        "durationMilliseconds": "10",
        "method": "GET",
        "status": "200",
        "url": "https://example.com/a",
      ])
  }

  @Test("A failure is logged at the failure level with the error's description in the message")
  func failureCarriesTheDescriptionInTheMessage() {
    let (capture, observer) = observed()
    observer.didFail(failure(.transport(kind: .timedOut, underlying: nil)))
    #expect(capture.only?.level == .error)
    #expect(capture.only?.message == "Send failed: transport failure (timedOut)")
    #expect(
      capture.only?.metadata == [
        "attempt": "2",
        "authAttached": "false",
        "correlationID": "8b1f",
        "durationMilliseconds": "25",
        "method": "POST",
        "url": "https://example.com/a",
      ])
  }

  @Test("A body that ended cleanly is logged with the bytes the reads returned")
  func cleanBodyCarriesTheByteCount() {
    let (capture, observer) = observed()
    observer.didFinishBody(bodyEnd(bytes: 4096))
    #expect(capture.only?.level == .debug)
    #expect(capture.only?.message == "Body ended")
    #expect(capture.only?.metadata == ["bytesReceived": "4096", "correlationID": "8b1f"])
  }

  @Test("A body that failed carries the failure in the message and still the byte count")
  func failedBodyCarriesBoth() {
    let (capture, observer) = observed()
    observer.didFinishBody(bodyEnd(bytes: 12, failure: .cancelled))
    #expect(capture.only?.level == .debug)
    #expect(capture.only?.message == "Body failed: cancelled")
    #expect(capture.only?.metadata == ["bytesReceived": "12", "correlationID": "8b1f"])
  }

  @Test("Each event kind is logged at the level the observer was given", arguments: levels)
  func everyKindHonoursItsLevel(level: Logger.Level) {
    let (capture, observer) = observed(
      bodyLevel: level, failureLevel: level, requestLevel: level, responseLevel: level)
    observer.willSend(request())
    observer.didReceive(response(status: .ok))
    observer.didFail(failure(.cancelled))
    observer.didFinishBody(bodyEnd(bytes: 1))
    #expect(capture.all.map(\.level) == [level, level, level, level])
  }

  @Test("A status the client rejects arrives as a response and is logged at the response level")
  func rejectedStatusIsStillAResponse() {
    let (capture, observer) = observed()
    observer.didReceive(response(status: .internalServerError))
    #expect(capture.only?.level == .info)
    #expect(capture.only?.metadata["status"] == "500")
  }

  @Test("A status failure logs neither the body it carried nor its header fields")
  func statusFailureKeepsTheBodyAndFieldsOut() {
    // The client reads the status outside the send it reports, so a status failure never reaches a
    // real observer through `didFail(_:)`. The case holds the line for the day one does.
    let (capture, observer) = observed()
    let secret = "s3cret"
    observer.didFail(
      failure(
        .httpStatus(
          body: Data(#"{"token":"s3cret"}"#.utf8),
          code: 401,
          headers: [.authorization: "Bearer s3cret"]
        )
      )
    )
    let written = capture.all.map { "\($0.message) \($0.metadata)" }.joined(separator: " ")
    #expect(!written.contains(secret))
    #expect(!written.lowercased().contains("authorization"))
    #expect(capture.only?.message == "Send failed: HTTP 401 with 18 body bytes")
  }

  @Test("A description that reads like a format specifier is logged as text")
  func aFormatShapedDescriptionIsCarriedVerbatim() {
    let (capture, observer) = observed()
    observer.didFail(failure(.decode(underlying: FormatShapedError())))
    #expect(capture.only?.message.hasPrefix("Send failed: ") == true)
    #expect(capture.only?.message.hasSuffix("%@ %s %d {0} %n") == true)
  }

  @Test("The observer asks for no body preview")
  func noBodyPreviewIsRequested() {
    let observer = observed().observer
    #expect(observer.bodyPreviewLimit == nil)
    #expect(observer.bodyPreview(of: Data("not-a-secret".utf8)) == nil)
  }

  @Test("A line below the handler's own level is never emitted")
  func aLineBelowTheHandlersLevelIsNeverEmitted() {
    let (capture, observer) = observed(handlerLevel: .error)
    observer.willSend(request())
    observer.didReceive(response(status: .ok))
    #expect(capture.all.isEmpty)
  }

  @Test("A response's body preview reaches no line, whatever an observer asked for")
  func aBodyPreviewReachesNoLine() {
    let (capture, observer) = observed()
    let preview = "not-a-secret-and-then-some"
    observer.didReceive(
      ResponseEvent(
        attempt: 1, authAttached: true, bodyPreview: Data(preview.utf8),
        correlationID: correlationID, duration: .milliseconds(10), method: .get, status: .ok,
        url: url))
    let written = capture.all.map { "\($0.message) \($0.metadata)" }.joined(separator: " ")
    #expect(!written.contains(preview))
    #expect(capture.only?.message == "Received response")
  }

  @Test("One observer logs every event when eight sends report at once")
  func concurrentSendsAreAllLogged() async {
    let (capture, observer) = observed()
    await withTaskGroup(of: Void.self) { group in
      for attempt in 1...8 {
        group.addTask {
          observer.willSend(
            RequestEvent(
              attempt: attempt, authAttached: true, correlationID: correlationID, method: .get,
              url: url))
        }
      }
    }
    #expect(
      Set(capture.all.compactMap { $0.metadata["attempt"] })
        == Set((1...8).map { String($0) })
    )
  }
}

#endif
