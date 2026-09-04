import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Compile-time check that a type is `Sendable`.
private func requireSendable<T: Sendable>(_: T.Type) {}

/// An error the tests pass as an underlying error.
private struct ProbeError: Error {}

/// The stored-property names of a value.
private func fieldNames(of value: Any) -> [String] {
  Mirror(reflecting: value).children.compactMap(\.label)
}

private let correlationID = "8b1f"
private let url = URL.fixture("https://example.com/a?b=c")

private let bodyEvent = BodyEvent(
  bytesReceived: 4096, correlationID: correlationID,
  failure: .transport(kind: .connectivity, underlying: ProbeError()))
private let failureEvent = FailureEvent(
  attempt: 2, authAttached: true, correlationID: correlationID, duration: .milliseconds(120),
  failure: .transport(kind: .timedOut, underlying: ProbeError()), method: .post, url: url)
private let requestEvent = RequestEvent(
  attempt: 1, authAttached: true, correlationID: correlationID, method: .get, url: url)
private let responseEvent = ResponseEvent(
  attempt: 1, authAttached: false, correlationID: correlationID, duration: .milliseconds(250),
  method: .get, status: .ok, url: url)

/// Words that must not appear in an event's stored-property names.
private let forbiddenFieldWords = ["authorization", "credential", "header", "secret", "token"]

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct TransportEventTests {
  @Test("The four event types are Sendable")
  func eventsAreSendable() {
    requireSendable(BodyEvent.self)
    requireSendable(FailureEvent.self)
    requireSendable(RequestEvent.self)
    requireSendable(ResponseEvent.self)
  }

  @Test("A request event carries the attempt's identity and nothing about the response")
  func requestEventFields() {
    #expect(
      fieldNames(of: requestEvent) == [
        "attempt", "authAttached", "correlationID", "method", "url",
      ])
    #expect(requestEvent.attempt == 1)
    #expect(requestEvent.authAttached)
    #expect(requestEvent.correlationID == correlationID)
    #expect(requestEvent.method == .get)
    #expect(requestEvent.url == url)
  }

  @Test("A response event carries the outcome, the timing, and no body by default")
  func responseEventFields() {
    #expect(
      fieldNames(of: responseEvent) == [
        "attempt", "authAttached", "bodyPreview", "correlationID", "duration", "method", "status",
        "url",
      ])
    #expect(responseEvent.bodyPreview == nil)
    #expect(responseEvent.duration == .milliseconds(250))
    #expect(responseEvent.status == .ok)
    #expect(!responseEvent.authAttached)
  }

  @Test("A failure event carries the failure, the attempt's own duration, and no body by default")
  func failureEventFields() {
    #expect(
      fieldNames(of: failureEvent) == [
        "attempt", "authAttached", "bodyPreview", "correlationID", "duration", "failure", "method",
        "url",
      ])
    #expect(failureEvent.bodyPreview == nil)
    #expect(failureEvent.duration == .milliseconds(120))
    #expect(failureEvent.failure.isTimeout)
    #expect(failureEvent.attempt == 2)
  }

  @Test("A body event carries the byte count, the identifier, and the failure that ended the body")
  func bodyEventFields() {
    #expect(fieldNames(of: bodyEvent) == ["bytesReceived", "correlationID", "failure"])
    #expect(bodyEvent.bytesReceived == 4096)
    #expect(bodyEvent.correlationID == correlationID)
    #expect(bodyEvent.failure?.underlying is ProbeError)
  }

  @Test("A body event's failure is nil by default, which is a clean end")
  func bodyEventEndsCleanlyByDefault() {
    let event = BodyEvent(bytesReceived: 0, correlationID: correlationID)
    #expect(event.failure == nil)
    #expect(event.bytesReceived == 0)
  }

  @Test("A failure status is reported as a response, because the origin answered")
  func failureStatusIsAResponseEvent() {
    let notFound = ResponseEvent(
      attempt: 1, authAttached: true, correlationID: correlationID, duration: .zero, method: .get,
      status: .notFound, url: url)
    #expect(notFound.status == .notFound)
    #expect(notFound.status.kind == .clientError)
  }

  @Test(
    "No event stores a credential or a header field",
    arguments: [
      fieldNames(of: bodyEvent), fieldNames(of: failureEvent), fieldNames(of: requestEvent),
      fieldNames(of: responseEvent),
    ])
  func eventsCarryNoCredentialFields(names: [String]) {
    for name in names {
      let lowercased = name.lowercased()
      for word in forbiddenFieldWords {
        #expect(!lowercased.contains(word), "\(name) must not exist on an event")
      }
    }
  }

  @Test("The only body an event can hold is the opt-in preview")
  func onlyBodyFieldIsThePreview() {
    let bodyFields =
      (fieldNames(of: bodyEvent) + fieldNames(of: failureEvent) + fieldNames(of: requestEvent)
      + fieldNames(of: responseEvent))
      .filter { $0.lowercased().contains("body") }
    #expect(Set(bodyFields) == ["bodyPreview"])
  }

  @Test("A preview travels as the bytes the client cut, not as a decoded string")
  func previewIsCarriedVerbatim() {
    let preview = Data("{\"error\":".utf8)
    let event = ResponseEvent(
      attempt: 1, authAttached: false, bodyPreview: preview, correlationID: correlationID,
      duration: .zero, method: .get, status: .internalServerError, url: url)
    #expect(event.bodyPreview == preview)
  }

  @Test("Attempts of one logical request share a correlation id and stay distinct values")
  func attemptsOfOneRequestAreDistinct() {
    let attempts = (1...3).map {
      RequestEvent(
        attempt: $0, authAttached: true, correlationID: correlationID, method: .get, url: url)
    }
    #expect(Set(attempts).count == 3)
    #expect(Set(attempts.map(\.correlationID)).count == 1)
  }

  @Test("Two events built the same way are the same value")
  func equalEventsAreEqual() {
    #expect(
      responseEvent
        == ResponseEvent(
          attempt: 1, authAttached: false, correlationID: correlationID,
          duration: .milliseconds(250), method: .get, status: .ok, url: url))
    #expect(
      requestEvent
        != RequestEvent(
          attempt: 1, authAttached: false, correlationID: correlationID, method: .get, url: url))
  }
}
