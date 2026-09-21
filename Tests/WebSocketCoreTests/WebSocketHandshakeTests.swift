#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPCore
import HTTPTesting
import HTTPTypes
import Synchronization
import Testing
import WebSocketCore

@Suite("WebSocket handshake policy", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct WebSocketHandshakeTests {
  private struct ParkedRefresher: TokenRefresher {
    let gate: WebSocketRendezvous
    let tokens: RecordingTokenProvider

    func refresh() async throws(TransportError) {
      do { try await gate.arriveAndWait() } catch { throw .cancelled }
      try await tokens.refresh()
    }
  }

  private final class ProbeProvider: TokenProvider {
    private let reads = Mutex(0)
    private let tokens: RecordingTokenProvider

    init(_ tokens: RecordingTokenProvider) { self.tokens = tokens }

    var readCount: Int { reads.withLock { $0 } }
    var timeUntilExpiry: Duration? {
      reads.withLock { $0 += 1 }
      return tokens.timeUntilExpiry
    }

    func currentToken() -> String? {
      reads.withLock { $0 += 1 }
      return tokens.currentToken()
    }
  }

  @Test(
    "Authentication renders each scheme and owns its field even without a token",
    arguments: [Authentication.Scheme.basic, .bearer, .field(HTTPField.Name("X-Key")!)])
  func authenticationRendersEachSchemeAndOwnsItsFieldEvenWithoutAToken(
    scheme: Authentication.Scheme
  ) async throws {
    let field: HTTPField.Name =
      scheme == .field(HTTPField.Name("X-Key")!) ? HTTPField.Name("X-Key")! : .authorization
    let tokens = RecordingTokenProvider(token: "secret")
    let transport = MockWebSocketTransport(answers: [
      .init(result: .success(ScriptedWebSocketConnection())),
      .init(result: .success(ScriptedWebSocketConnection())),
    ])
    let request = WebSocketRequest(
      authentication: Authentication(provider: tokens, scheme: scheme),
      headers: [field: "caller"], url: URL(string: "wss://example.com/socket")!)
    _ = try await open(request, transport: transport)
    let expected: String
    switch scheme {
    case .basic: expected = "Basic secret"
    case .bearer: expected = "Bearer secret"
    case .field: expected = "secret"
    }
    #expect(transport.calls[0].request.headers[field] == expected)
    #expect(transport.calls[0].request.authentication == nil)

    let absent = WebSocketRequest(
      authentication: Authentication(provider: RecordingTokenProvider(), scheme: scheme),
      headers: [field: "caller"], url: request.url)
    _ = try await open(absent, transport: transport)
    #expect(transport.calls[1].request.headers[field] == nil)
    #expect(request.headers[field] == "caller")
  }

  @Test(
    "Cancellation and deadline leave shared rotation running for HTTP",
    arguments: [false, true])
  func cancellationAndDeadlineLeaveSharedRotationRunningForHTTP(cancel: Bool) async throws {
    let clock = RecordingClock()
    let gate = WebSocketRendezvous()
    defer { gate.release() }
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.success("new")], timeUntilExpiry: .zero, token: "old")
    let authentication = Authentication(
      provider: tokens, refresher: ParkedRefresher(gate: gate, tokens: tokens),
      refreshThreshold: .seconds(30))
    let transport = MockWebSocketTransport()
    let request = WebSocketRequest(
      authentication: authentication, url: URL(string: "wss://example.com/socket")!)
    let socket = Task { try await open(request, clock: clock, transport: transport) }
    try await gate.waitForArrival()
    let http = MockTransport(results: [.success(.empty(status: .ok))])
    let client = HTTPClient(
      authentication: authentication, baseURL: URL(string: "https://example.com")!,
      clock: RecordingClock(), transport: http)
    // HTTP reaches the already-live gate before its first suspension.
    let survivor = Task.immediate { try await client.execute(Request(path: "/")) as Response }
    await clock.waitForPendingSleep()
    if cancel { socket.cancel() } else { clock.advance(by: .seconds(30)) }
    let error = await failure { _ = try await socket.value }
    #expect(error?.kind == (cancel ? .cancelled : .timedOut))
    #expect(tokens.currentToken() == "old")
    #expect(transport.calls.isEmpty)
    #expect(http.requests.isEmpty)
    gate.release()
    #expect(try await survivor.value.status == .ok)
    #expect(tokens.refreshes == 1)
    #expect(http.last?.request.headerFields[.authorization] == "Bearer new")
    #expect(transport.calls.isEmpty)
    #expect(clock.pendingSleeps == 0)
  }

  @Test("Completion racing cancellation and expiry settles once", arguments: 0..<8)
  func completionRacingCancellationAndExpirySettlesOnce(iteration: Int) async throws {
    let clock = RecordingClock()
    let gate = WebSocketRendezvous()
    defer { gate.release() }
    let connection = ScriptedWebSocketConnection()
    let discards = Mutex(0)
    let transport = MockWebSocketTransport(answers: [
      .init(gate: gate, result: .success(connection))
    ])
    let request = WebSocketRequest(url: URL(string: "wss://example.com")!)
    let call = Task {
      try await WebSocketHandshake.connect(
        request, clock: clock, discard: { _ in discards.withLock { $0 += 1 } }
      ) { request throws(WebSocketError) in
        try await transport.connect(request)
      }
    }
    try await gate.waitForArrival()
    await clock.waitForPendingSleep()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { call.cancel() }
      group.addTask { clock.advanceAll() }
      group.addTask { gate.release() }
    }
    do {
      #expect(try await call.value === connection)
    } catch {
      let error = try #require(error as? WebSocketError)
      #expect(error.kind == .cancelled || error.kind == .timedOut)
    }
    #expect(transport.calls.count == 1)
    #expect(discards.withLock { $0 } <= 1)
    #expect(clock.pendingSleeps == 0)
  }

  @Test("Credential failure propagates without a handshake replay")
  func credentialFailurePropagatesWithoutAHandshakeReplay() async throws {
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.failure(.transport(kind: .timedOut, underlying: nil))], token: "old")
    let transport = MockWebSocketTransport(answers: [
      .init(
        result: .failure(
          WebSocketError(kind: .handshakeRejected, response: .init(status: .unauthorized))))
    ])
    let request = WebSocketRequest(
      authentication: Authentication(provider: tokens, refresher: tokens),
      url: URL(string: "wss://example.com")!)
    let error = await failure { _ = try await open(request, transport: transport) }
    #expect(error?.kind == .transport)
    let underlying = try #require(error?.underlying as? TransportError)
    guard case .transport(let kind, _) = underlying else {
      Issue.record("Expected the original transport failure")
      return
    }
    #expect(kind == .timedOut)
    #expect(tokens.refreshes == 1)
    #expect(transport.calls.count == 1)
  }

  @Test("Custom connect timeouts expire on the injected clock")
  func customConnectTimeoutsExpireOnTheInjectedClock() async throws {
    let clock = RecordingClock()
    let gate = WebSocketRendezvous()
    defer { gate.release() }
    let transport = MockWebSocketTransport(answers: [
      .init(gate: gate, result: .success(ScriptedWebSocketConnection()))
    ])
    let request = WebSocketRequest(url: URL(string: "wss://example.com")!)
    let call = Task {
      try await WebSocketHandshake.connect(
        request, clock: clock, discard: { _ in }, timeout: .seconds(2)
      ) { request throws(WebSocketError) in
        try await transport.connect(request)
      }
    }
    try await gate.waitForArrival()
    await clock.waitForPendingSleep()
    clock.advance(by: .seconds(2))
    #expect(await failure { _ = try await call.value }?.kind == .timedOut)
    #expect(clock.sleeps == [.seconds(2)])
    #expect(clock.pendingSleeps == 0)
  }

  @Test(
    "Invalid and insecure requests fail before reading credentials",
    arguments: [
      "/relative", "https://example.com", "wss://example.com/#fragment",
      "wss://user:password@example.com", "wss://example.com:0",
      "wss://example.com:65536", "wss://example.com:", "ws://example.com",
    ])
  func invalidAndInsecureRequestsFailBeforeReadingCredentials(address: String) async throws {
    let tokens = RecordingTokenProvider(
      refreshOutcomes: [.success("new")], timeUntilExpiry: .zero, token: "old")
    let provider = ProbeProvider(tokens)
    let transport = MockWebSocketTransport()
    let request = WebSocketRequest(
      authentication: Authentication(
        provider: provider, refresher: tokens, refreshThreshold: .seconds(30)),
      url: try #require(URL(string: address)))
    let error = await failure { _ = try await open(request, transport: transport) }
    #expect(error?.kind == .invalidRequest)
    #expect(provider.readCount == 0)
    #expect(tokens.refreshes == 0)
    #expect(transport.calls.isEmpty)
  }

  @Test("Invalid credential bytes are rejected before header legalization")
  func invalidCredentialBytesAreRejectedBeforeHeaderLegalization() async throws {
    let transport = MockWebSocketTransport()
    let request = WebSocketRequest(
      authentication: Authentication(
        provider: RecordingTokenProvider(token: "secret\r\nInjected: yes")),
      url: URL(string: "wss://example.com")!)
    let error = await failure { _ = try await open(request, transport: transport) }
    #expect(error?.kind == .invalidRequest)
    #expect(transport.calls.isEmpty)
  }

  @Test(
    "Invalid subprotocol offers fail before reading credentials",
    arguments: [[""], ["chat room"], ["a,b"], ["chat", "chat"], ["é"]])
  func invalidSubprotocolOffersFailBeforeReadingCredentials(protocols: [String]) async {
    let provider = ProbeProvider(RecordingTokenProvider(token: "old"))
    let transport = MockWebSocketTransport()
    let request = WebSocketRequest(
      authentication: Authentication(provider: provider), subprotocols: protocols,
      url: URL(string: "wss://example.com")!)
    #expect(
      await failure { _ = try await open(request, transport: transport) }?.kind == .invalidRequest)
    #expect(provider.readCount == 0)
    #expect(transport.calls.isEmpty)
  }

  @Test("Late backend success is discarded after cancellation or expiry", arguments: [false, true])
  func lateBackendSuccessIsDiscardedAfterCancellationOrExpiry(cancel: Bool) async throws {
    let clock = RecordingClock()
    let discarded = WebSocketRendezvous()
    let gate = WebSocketRendezvous()
    defer { gate.release() }
    let count = Mutex(0)
    let connection = ScriptedWebSocketConnection()
    let request = WebSocketRequest(url: URL(string: "wss://example.com")!)
    let call = Task {
      try await WebSocketHandshake.connect(
        request, clock: clock,
        discard: { _ in
          count.withLock { $0 += 1 }
          discarded.release()
        }
      ) { _ throws(WebSocketError) in
        // This fixture deliberately ignores cancellation; its owned task is released below.
        let work = Task { () -> Result<ScriptedWebSocketConnection, WebSocketError> in
          do throws(WebSocketError) {
            try await gate.arriveAndWait()
            return .success(connection)
          } catch {
            return .failure(error)
          }
        }
        return try await work.value.get()
      }
    }
    try await gate.waitForArrival()
    await clock.waitForPendingSleep()
    if cancel { call.cancel() } else { clock.advanceAll() }
    #expect(await failure { _ = try await call.value }?.kind == (cancel ? .cancelled : .timedOut))
    #expect(count.withLock { $0 } == 0)
    gate.release()
    try await discarded.arriveAndWait()
    #expect(count.withLock { $0 } == 1)
    #expect(clock.pendingSleeps == 0)
  }

  @Test("One deadline covers the first handshake refresh and replay")
  func oneDeadlineCoversTheFirstHandshakeRefreshAndReplay() async throws {
    let clock = RecordingClock()
    let first = WebSocketRendezvous()
    let refresh = WebSocketRendezvous()
    let replay = WebSocketRendezvous()
    defer { first.release(); refresh.release(); replay.release() }
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("new")], token: "old")
    let transport = MockWebSocketTransport(answers: [
      .init(
        gate: first,
        result: .failure(
          WebSocketError(
            kind: .handshakeRejected, response: .init(status: .unauthorized)))),
      .init(gate: replay, result: .success(ScriptedWebSocketConnection())),
    ])
    let request = WebSocketRequest(
      authentication: Authentication(
        provider: tokens, refresher: ParkedRefresher(gate: refresh, tokens: tokens)),
      url: URL(string: "wss://example.com")!)
    let call = Task { try await open(request, clock: clock, transport: transport) }
    try await first.waitForArrival()
    await clock.waitForPendingSleep()
    clock.advance(by: .seconds(10))
    first.release()
    try await refresh.waitForArrival()
    clock.advance(by: .seconds(10))
    refresh.release()
    try await replay.waitForArrival()
    clock.advance(by: .seconds(10))
    #expect(await failure { _ = try await call.value }?.kind == .timedOut)
    #expect(clock.sleeps == [.seconds(30)])
    #expect(
      transport.calls.map { $0.request.headers[.authorization] } == ["Bearer old", "Bearer new"])
    #expect(tokens.refreshes == 1)
    #expect(clock.pendingSleeps == 0)
  }

  @Test(
    "Only an eligible known 401 refreshes and replays",
    arguments: [Optional<Int>.none, 301, 307, 401, 403])
  func onlyAnEligibleKnown401RefreshesAndReplays(status: Int?) async throws {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("new")], token: "old")
    let rejected = WebSocketError(
      kind: .handshakeRejected, response: status.map { HTTPResponse(status: .init(code: $0)) })
    let transport = MockWebSocketTransport(answers: [
      .init(result: .failure(rejected)), .init(result: .success(ScriptedWebSocketConnection())),
    ])
    let request = WebSocketRequest(
      authentication: Authentication(provider: tokens, refresher: tokens),
      url: URL(string: "wss://example.com")!)
    let error = await failure { _ = try await open(request, transport: transport) }
    if status == 401 {
      #expect(error == nil)
      #expect(tokens.refreshes == 1)
      #expect(
        transport.calls.map { $0.request.headers[.authorization] } == ["Bearer old", "Bearer new"])
    } else {
      #expect(error?.response?.status.code == status)
      #expect(error?.kind == .handshakeRejected)
      #expect(tokens.refreshes == 0)
      #expect(transport.calls.count == 1)
    }
  }

  @Test("Precancelled calls perform no validation credential or backend work")
  func precancelledCallsPerformNoValidationCredentialOrBackendWork() async {
    let gate = WebSocketRendezvous()
    let provider = ProbeProvider(RecordingTokenProvider(token: "old"))
    let transport = MockWebSocketTransport()
    let request = WebSocketRequest(
      authentication: Authentication(provider: provider), url: URL(string: "https://example.com")!)
    let call = Task.immediate {
      try? await gate.arriveAndWait()
      return try await open(request, transport: transport)
    }
    call.cancel()
    #expect(await failure { _ = try await call.value }?.kind == .cancelled)
    #expect(provider.readCount == 0)
    #expect(transport.calls.isEmpty)
  }

  @Test("Replay configuration and a missing refresher prevent replay", arguments: [false, true])
  func replayConfigurationAndAMissingRefresherPreventReplay(replayEnabled: Bool) async {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("new")], token: "old")
    let transport = MockWebSocketTransport(answers: [
      .init(
        result: .failure(
          WebSocketError(kind: .handshakeRejected, response: .init(status: .unauthorized))))
    ])
    let request = WebSocketRequest(
      authentication: Authentication(
        provider: tokens, refresher: replayEnabled ? nil : tokens, replayOn401: replayEnabled),
      url: URL(string: "wss://example.com")!)
    #expect(
      await failure { _ = try await open(request, transport: transport) }?.kind
        == .handshakeRejected)
    #expect(tokens.refreshes == 0)
    #expect(transport.calls.count == 1)
  }

  @Test(
    "Reserved headers and credential field names fail before provider access",
    arguments: [
      "Connection", "Host", "Upgrade", "Sec-WebSocket-Key", "Sec-WebSocket-Protocol",
      "Sec-WebSocket-Version", "Content-Length",
    ])
  func reservedHeadersAndCredentialFieldNamesFailBeforeProviderAccess(name: String) async throws {
    let field = try #require(HTTPField.Name(name))
    let provider = ProbeProvider(RecordingTokenProvider(token: "old"))
    let transport = MockWebSocketTransport()
    let headerRequest = WebSocketRequest(
      authentication: Authentication(provider: provider), headers: [field: "override"],
      url: URL(string: "wss://example.com")!)
    #expect(
      await failure { _ = try await open(headerRequest, transport: transport) }?.kind
        == .invalidRequest)
    let credentialRequest = WebSocketRequest(
      authentication: Authentication(provider: provider, scheme: .field(field)),
      url: headerRequest.url)
    #expect(
      await failure { _ = try await open(credentialRequest, transport: transport) }?.kind
        == .invalidRequest)
    #expect(provider.readCount == 0)
    #expect(transport.calls.isEmpty)
  }

  @Test("Second unauthorized responses propagate without another refresh")
  func secondUnauthorizedResponsesPropagateWithoutAnotherRefresh() async {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("new")], token: "old")
    let rejected = WebSocketError(
      kind: .handshakeRejected,
      response: .init(status: .unauthorized, headerFields: [.wwwAuthenticate: "Bearer"]))
    let transport = MockWebSocketTransport(answers: [
      .init(result: .failure(rejected)), .init(result: .failure(rejected)),
    ])
    let request = WebSocketRequest(
      authentication: Authentication(provider: tokens, refresher: tokens),
      url: URL(string: "wss://example.com")!)
    let error = await failure { _ = try await open(request, transport: transport) }
    #expect(error?.response?.headerFields[.wwwAuthenticate] == "Bearer")
    #expect(tokens.refreshes == 1)
    #expect(transport.calls.count == 2)
  }

  @Test("Stale rejected tokens replay with the installed credential without refreshing")
  func staleRejectedTokensReplayWithTheInstalledCredentialWithoutRefreshing() async throws {
    let gate = WebSocketRendezvous()
    defer { gate.release() }
    let tokens = RecordingTokenProvider(token: "old")
    let transport = MockWebSocketTransport(answers: [
      .init(
        gate: gate,
        result: .failure(
          WebSocketError(
            kind: .handshakeRejected, response: .init(status: .unauthorized)))),
      .init(result: .success(ScriptedWebSocketConnection())),
    ])
    let request = WebSocketRequest(
      authentication: Authentication(provider: tokens, refresher: tokens),
      url: URL(string: "wss://example.com")!)
    let call = Task { try await open(request, transport: transport) }
    try await gate.waitForArrival()
    tokens.install(token: "external")
    gate.release()
    _ = try await call.value
    #expect(tokens.refreshes == 0)
    #expect(
      transport.calls.map { $0.request.headers[.authorization] } == [
        "Bearer old", "Bearer external",
      ])
  }

  @Test(
    "Timeouts must be positive before credential access", arguments: [Duration.zero, .seconds(-1)])
  func timeoutsMustBePositiveBeforeCredentialAccess(timeout: Duration) async {
    let clock = RecordingClock()
    let provider = ProbeProvider(RecordingTokenProvider(token: "old"))
    let request = WebSocketRequest(
      authentication: Authentication(provider: provider), url: URL(string: "wss://example.com")!)
    let transport = MockWebSocketTransport()
    let error = await failure {
      _ = try await WebSocketHandshake.connect(
        request, clock: clock, discard: { _ in }, timeout: timeout
      ) {
        request throws(WebSocketError) in
        try await transport.connect(request)
      }
    }
    #expect(error?.kind == .invalidRequest)
    #expect(provider.readCount == 0)
    #expect(transport.calls.isEmpty)
    #expect(clock.sleeps.isEmpty)
  }

  @Test("Transport failures carrying unauthorized diagnostics never trigger replay")
  func transportFailuresCarryingUnauthorizedDiagnosticsNeverTriggerReplay() async {
    let tokens = RecordingTokenProvider(refreshOutcomes: [.success("new")], token: "old")
    let transport = MockWebSocketTransport(answers: [
      .init(
        result: .failure(
          WebSocketError(
            kind: .transport, response: .init(status: .unauthorized),
            underlying: TransportError.httpStatus(body: Data(), code: 401, headers: [:]))))
    ])
    let request = WebSocketRequest(
      authentication: Authentication(provider: tokens, refresher: tokens),
      url: URL(string: "wss://example.com")!)
    #expect(await failure { _ = try await open(request, transport: transport) }?.kind == .transport)
    #expect(tokens.refreshes == 0)
    #expect(transport.calls.count == 1)
  }

  @Test(
    "Valid URLs headers and ordered offers reach the backend unchanged",
    arguments: [
      "ws://example.com/a%2Fb?q=%2F", "wss://[::1]:8443/a", "wss://[::ffff:192.0.2.1]/",
      "wss://example.com:443/",
    ])
  func validURLsHeadersAndOrderedOffersReachTheBackendUnchanged(address: String) async throws {
    let clock = RecordingClock()
    let transport = MockWebSocketTransport(answers: [
      .init(result: .success(ScriptedWebSocketConnection()))
    ])
    let request = WebSocketRequest(
      headers: [.cookie: "a=b", .origin: "https://example.com"], subprotocols: ["chat", "Chat"],
      url: try #require(URL(string: address)))
    _ = try await open(request, clock: clock, transport: transport)
    let sent = try #require(transport.calls.first?.request)
    #expect(sent.url.absoluteString == address)
    #expect(sent.headers == [.cookie: "a=b", .origin: "https://example.com"])
    #expect(sent.subprotocols == ["chat", "Chat"])
    #expect(clock.pendingSleeps == 0)
  }

  private func failure(_ operation: () async throws -> Void) async -> WebSocketError? {
    do {
      try await operation()
      return nil
    } catch {
      guard let error = error as? WebSocketError else {
        Issue.record("A handshake threw an unexpected error type")
        return nil
      }
      return error
    }
  }

  private func open(
    _ request: WebSocketRequest,
    clock: RecordingClock = RecordingClock(),
    transport: MockWebSocketTransport
  ) async throws(WebSocketError) -> ScriptedWebSocketConnection {
    try await WebSocketHandshake.connect(request, clock: clock, discard: { _ in }) {
      request throws(WebSocketError) in
      try await transport.connect(request)
    }
  }
}
