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

@Suite("HTTP transport compatibility", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPCompatibilityTests {
  private struct StreamOnlyTransport: Transport {
    func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
      async throws(TransportError) -> StreamedResponse
    {
      let chunks = AsyncStream<Data> { continuation in
        continuation.yield(Data([1, 2, 3]))
        continuation.finish()
      }
      return StreamedResponse(body: StreamedBody(chunks), headers: [:], status: .ok)
    }
  }

  @Test("An HTTP conformer still supplies only stream and inherits buffered send")
  func streamOnlyConformerRetainsBufferedSend() async throws {
    let request = HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/")
    let response = try await StreamOnlyTransport().send(request, body: .none, options: .init())
    #expect(response.body == Data([1, 2, 3]))
    #expect(response.status == .ok)
  }
}

@Suite("HTTP and WebSocket shared credentials", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct SharedCredentialTests {
  private struct ParkedRefresher: TokenRefresher {
    let clock: RecordingClock
    let tokens: RecordingTokenProvider

    func refresh() async throws(TransportError) {
      do {
        try await clock.sleep(for: .seconds(1))
      } catch {
        throw .cancelled
      }
      try await tokens.refresh()
    }
  }

  @Test(
    "Cancelling a WebSocket credential wait preserves the contending HTTP request",
    arguments: [false, true])
  func cancellingAWebSocketCredentialWaitPreservesTheContendingHTTPRequest(
    webSocketLeads: Bool
  ) async throws {
    let clock = RecordingClock()
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.success("new")], timeUntilExpiry: .zero, token: "old")
    let authentication = Authentication(
      provider: tokens, refresher: ParkedRefresher(clock: clock, tokens: tokens),
      refreshThreshold: .seconds(30))
    let http = MockTransport(results: [.success(.empty(status: .ok))])
    let client = HTTPClient(
      authentication: authentication, baseURL: URL(string: "https://example.com")!,
      clock: RecordingClock(), transport: http)
    var request = WebSocketRequest(
      authentication: authentication, url: URL(string: "wss://example.com/socket")!)
    request.authentication?.replayOn401 = false
    let credential = try #require(request.authentication)

    let httpCall: Task<Response, any Error>
    let webSocketCall: Task<Void, any Error>
    if webSocketLeads {
      webSocketCall = Task.immediate { try await credential.refreshIfExpiring() }
      httpCall = Task.immediate { try await client.execute(Request(path: "/")) as Response }
    } else {
      httpCall = Task.immediate { try await client.execute(Request(path: "/")) as Response }
      webSocketCall = Task.immediate { try await credential.refreshIfExpiring() }
    }
    await clock.waitForPendingSleep()
    webSocketCall.cancel()
    do {
      try await webSocketCall.value
      Issue.record("A cancelled credential waiter succeeded")
    } catch {
      #expect((error as? TransportError)?.description == "cancelled")
    }
    #expect(tokens.currentToken() == "old")
    #expect(http.requests.isEmpty)
    #expect(clock.pendingSleeps == 1)
    clock.advanceAll()
    #expect(try await httpCall.value.status == .ok)
    #expect(tokens.refreshes == 1)
    #expect(http.requests.count == 1)
    #expect(http.last?.request.headerFields[.authorization] == "Bearer new")
  }

  @Test("New authentication values over one provider keep independent refresh identities")
  func newAuthenticationValuesOverOneProviderKeepIndependentRefreshIdentities() async throws {
    let clock = RecordingClock()
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.success("first"), .success("second")], token: "old")
    let refresher = ParkedRefresher(clock: clock, tokens: tokens)
    let first = Authentication(provider: tokens, refresher: refresher)
    let second = WebSocketRequest(
      authentication: Authentication(provider: tokens, refresher: refresher),
      url: URL(string: "wss://example.com/socket")!)
    let firstCall = Task.immediate { try await first.refresh(replacing: "old") }
    let secondCall = Task.immediate { try await second.authentication?.refresh(replacing: "old") }
    await clock.waitForPendingSleep(count: 2)
    clock.advanceAll()
    try await firstCall.value
    try await secondCall.value
    #expect(tokens.refreshes == 2)
  }
}
