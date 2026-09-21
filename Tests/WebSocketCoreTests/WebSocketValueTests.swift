#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing
import WebSocketCore
import WebSocketTestSupport

@Suite("WebSocket values", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct WebSocketValueTests {
  private struct Diagnostic: CustomStringConvertible, Error {
    var description: String { "secret underlying text" }
  }

  @Test("Close codes preserve private and reserved raw values without implying validation")
  func closeCodesPreserveRawValues() {
    #expect(WebSocket.CloseCode.normalClosure.rawValue == 1000)
    #expect(WebSocket.CloseCode.goingAway.rawValue == 1001)
    #expect(WebSocket.CloseCode(rawValue: 4001).rawValue == 4001)
    #expect(WebSocket.CloseCode(rawValue: 1005).rawValue == 1005)
    #expect(WebSocketClose().code == nil)
    #expect(WebSocketClose().reason == nil)
  }

  @Test("Error descriptions omit arbitrary diagnostic values")
  func descriptionsOmitDiagnostics() {
    let response = HTTPResponse(status: .unauthorized, headerFields: [.wwwAuthenticate: "secret"])
    let error = WebSocketError(
      close: WebSocketClose(code: .init(rawValue: 4001), reason: "secret peer reason"),
      kind: .handshakeRejected,
      response: response,
      underlying: Diagnostic()
    )
    #expect(error.description == "WebSocket failure: handshakeRejected")
    #expect(error.response?.status.code == 401)
    #expect(error.response?.headerFields[.wwwAuthenticate] == "secret")
    #expect(error.close?.reason == "secret peer reason")
    #expect(error.underlying is Diagnostic)
    let custom = WebSocketError(kind: .init(rawValue: "secret custom kind"))
    #expect(custom.description == "WebSocket failure: custom")
    #expect(custom.kind.rawValue == "secret custom kind")
    #expect(custom.response == nil)
    #expect(WebSocketError(kind: .sendQueueFull).description == "WebSocket failure: sendQueueFull")
  }

  @Test("Message sizes count UTF-8 bytes and preserve empty messages")
  func messagesCountPayloadBytes() {
    #expect(WebSocketFixtures.messages.map(\.byteCount) == [3, 5, 6, 0, 0])
    #expect(WebSocket.Message.binary(Data()) != .text(""))
  }

  @Test("Requests preserve escaping and offered subprotocol order")
  func requestsPreserveInputs() throws {
    let url = try #require(URL(string: "wss://example.com/a%2Fb?q=%26"))
    let request = WebSocketRequest(
      headers: [.origin: "https://example.com"],
      subprotocols: ["second", "first"],
      url: url
    )
    #expect(request.headers[.origin] == "https://example.com")
    #expect(request.subprotocols == ["second", "first"])
    #expect(request.url.absoluteString == "wss://example.com/a%2Fb?q=%26")
    #expect(request.authentication == nil)
  }

  @Test("Send options retain approved defaults and independently adjustable values")
  func sendOptionsRetainConfiguration() {
    let original = WebSocket.Options()
    #expect(original.maxPendingSendBytes == 1_048_576)
    #expect(original.maxPendingSendMessages == 16)
    #expect(original.sendFailurePolicy == .preserveIfUnsent)
    #expect(original.sendPolicy == .serialize)
    var changed = original
    changed.maxPendingSendBytes = 2_097_152
    changed.maxPendingSendMessages = 32
    changed.sendFailurePolicy = .abortConnection
    changed.sendPolicy = .rejectOverlapping
    #expect(
      changed
        == .init(
          maxPendingSendBytes: 2_097_152, maxPendingSendMessages: 32,
          sendFailurePolicy: .abortConnection, sendPolicy: .rejectOverlapping))
    #expect(original.maxPendingSendMessages == 16)
    #expect(
      WebSocket.Options(maxPendingSendBytes: 8, maxPendingSendMessages: 1).maxPendingSendBytes == 8)
  }
}
