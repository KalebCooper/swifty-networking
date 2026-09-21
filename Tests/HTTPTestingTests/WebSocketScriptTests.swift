#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTesting
import HTTPTypes
import Testing
import WebSocketCore
import WebSocketTestSupport

@Suite("WebSocket scripts", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct WebSocketScriptTests {
  @Test(
    "Backend protocol calls reject an incompatible scripted outcome",
    arguments: [
      ScriptedWebSocketConnection.Operation.close(code: .normalClosure, reason: nil),
      .ping, .receive, .send(.text("message")),
    ])
  func backendCallsRejectMismatchedOutcomes(_ operation: ScriptedWebSocketConnection.Operation)
    async
  {
    let outcome: ScriptedWebSocketConnection.Outcome =
      operation == .receive ? .completed : .message(nil)
    let connection = ScriptedWebSocketConnection(steps: [.init(result: .success(outcome))])
    do throws(WebSocketError) {
      switch operation {
      case .cancel: Issue.record("Cancellation has no asynchronous result")
      case .close(let code, let reason): _ = try await connection.close(code: code, reason: reason)
      case .ping: try await connection.ping()
      case .receive: _ = try await connection.receive()
      case .send(let message): try await connection.send(message)
      }
      Issue.record("An incompatible outcome was accepted")
    } catch {
      #expect(error.kind == .transport)
      #expect(error.underlying as? WebSocketScriptFailure == .mismatchedOutcome)
    }
    #expect(connection.operations == [operation])
  }

  @Test("Backend protocol calls consume their seeded outcomes and synchronous abort consumes none")
  func backendCallsReplaySeededOutcomes() async throws {
    let close = WebSocketClose(code: .init(rawValue: 4001), reason: "done")
    let connection = ScriptedWebSocketConnection(
      closeInfo: close, negotiatedSubprotocol: "chat",
      steps: [
        .init(result: .success(.completed)),
        .init(result: .success(.message(.text("received")))),
        .init(result: .success(.completed)),
        .init(result: .success(.close(close))),
      ])
    let backend: any WebSocketConnection = connection
    backend.cancel()
    try await connection.waitForCancellation()
    try await backend.ping()
    #expect(try await backend.receive() == .text("received"))
    try await backend.send(.text("sent"))
    #expect(try await backend.close(code: .normalClosure, reason: "bye") == close)
    #expect(backend.closeInfo == close)
    #expect(backend.negotiatedSubprotocol == "chat")
    #expect(
      connection.operations == [
        .cancel, .ping, .receive, .send(.text("sent")), .close(code: .normalClosure, reason: "bye"),
      ])
  }

  @Test("An exhausted script records its call and throws a named fixture failure")
  func exhaustedScriptFailsExplicitly() async {
    let connection = ScriptedWebSocketConnection()
    do {
      _ = try await connection.perform(.receive)
      Issue.record("The empty script returned an outcome.")
    } catch {
      #expect(error.kind == .transport)
      #expect(error.underlying as? WebSocketScriptFailure == .noScriptedOutcome)
    }
    #expect(connection.operations == [.receive])
  }

  @Test("Concurrent cancellation and release settle every parked operation once")
  func gateCancellationAndReleaseSettleEveryCaller() async throws {
    let gate = WebSocketRendezvous()
    let calls = (0..<8).map { _ in
      Task { () -> Result<Void, WebSocketError> in
        do throws(WebSocketError) {
          try await gate.arriveAndWait()
          return .success(())
        } catch {
          return .failure(error)
        }
      }
    }
    try await gate.waitForArrival(count: 8)
    await withTaskGroup(of: Void.self) { group in
      group.addTask { for call in calls { call.cancel() } }
      group.addTask { gate.release() }
    }
    for call in calls {
      if case .failure(let error) = await call.value {
        #expect(error.kind == .cancelled)
      }
    }
    #expect(gate.arrivals == 8)
    #expect(gate.pendingWaiters == 0)
  }

  @Test("Cancellation removes one parked operation and leaves the next seeded outcome available")
  func gateCancellationDoesNotInventLifecyclePolicy() async throws {
    let gate = WebSocketRendezvous()
    let connection = ScriptedWebSocketConnection(steps: [
      .init(gate: gate, result: .success(.completed)),
      .init(result: .success(.message(.text("next")))),
    ])
    let operation = Task { try await connection.perform(.send(.text("first"))) }
    try await gate.waitForArrival()
    operation.cancel()
    do {
      _ = try await operation.value
      Issue.record("The parked call ignored cancellation.")
    } catch let error as WebSocketError {
      #expect(error.kind == .cancelled)
    }
    #expect(gate.pendingWaiters == 0)
    gate.release()
    #expect(try await connection.perform(.receive) == .message(.text("next")))
    #expect(connection.operations == [.send(.text("first")), .receive])
  }

  @Test("An arrival observer can be cancelled before any operation arrives")
  func gateObserverCanBeCancelled() async throws {
    let gate = WebSocketRendezvous()
    let observer = Task { try await gate.waitForArrival() }
    observer.cancel()
    do {
      try await observer.value
      Issue.record("The cancelled observer succeeded.")
    } catch let error as WebSocketError {
      #expect(error.kind == .cancelled)
    }
    #expect(gate.arrivals == 0)
    #expect(gate.pendingWaiters == 0)
  }

  @Test("Release before arrival and repeated release leave no suspended operation")
  func gateReleaseBeforeArrivalIsRetained() async throws {
    let gate = WebSocketRendezvous()
    gate.release()
    gate.release()
    try await gate.arriveAndWait()
    try await gate.waitForArrival()
    #expect(gate.arrivals == 1)
    #expect(gate.pendingWaiters == 0)
  }

  @Test("Concurrent operations consume every seeded result exactly once")
  func operationsConsumeResultsUnderContention() async throws {
    let gate = WebSocketRendezvous()
    let connection = ScriptedWebSocketConnection(
      steps: (0..<8).map { .init(gate: gate, result: .success(.message(.text(String($0))))) }
    )
    let values = try await withThrowingTaskGroup(of: ScriptedWebSocketConnection.Outcome.self) {
      group in
      for _ in 0..<8 { group.addTask { try await connection.perform(.receive) } }
      try await gate.waitForArrival(count: 8)
      #expect(connection.operations.count == 8)
      gate.release()
      var values: [String] = []
      for try await value in group {
        if case .message(.text(let text)) = value { values.append(text) }
      }
      return values.sorted()
    }
    #expect(values == ["0", "1", "2", "3", "4", "5", "6", "7"])
    #expect(gate.pendingWaiters == 0)
  }

  @Test("A script replays messages and errors without interpreting close or cancel operations")
  func operationsReplayOnlySeededOutcomes() async throws {
    let close = WebSocketClose(code: .init(rawValue: 4001), reason: "reason")
    let connection = ScriptedWebSocketConnection(
      steps:
        WebSocketFixtures.messages.map { .init(result: .success(.message($0))) } + [
          .init(result: .success(.close(close))),
          .init(result: .failure(WebSocketError(kind: .sendQueueFull))),
          .init(result: .success(.message(nil))),
        ])
    for message in WebSocketFixtures.messages {
      #expect(try await connection.perform(.receive) == .message(message))
    }
    #expect(
      try await connection.perform(.close(code: .normalClosure, reason: nil)) == .close(close))
    do {
      _ = try await connection.perform(.send(.text("queued")))
      Issue.record("The seeded failure was not returned.")
    } catch {
      #expect(error.kind == .sendQueueFull)
    }
    #expect(try await connection.perform(.cancel) == .message(nil))
    #expect(connection.operations.count == 8)
  }

  @Test("Concurrent connects consume every seeded connection once and record every request")
  func transportConsumesConnectionsUnderContention() async throws {
    let gate = WebSocketRendezvous()
    let connections = (0..<8).map { _ in ScriptedWebSocketConnection() }
    let transport = MockWebSocketTransport(
      answers: connections.map {
        .init(gate: gate, result: .success($0))
      })
    let url = try #require(URL(string: "wss://example.com"))
    let received = try await withThrowingTaskGroup(of: ScriptedWebSocketConnection.self) { group in
      for index in 0..<8 {
        group.addTask {
          try await transport.connect(WebSocketRequest(subprotocols: [String(index)], url: url))
        }
      }
      try await gate.waitForArrival(count: 8)
      #expect(transport.calls.count == 8)
      gate.release()
      var received: Set<ObjectIdentifier> = []
      for try await connection in group { received.insert(ObjectIdentifier(connection)) }
      return received
    }
    #expect(received == Set(connections.map(ObjectIdentifier.init)))
    #expect(
      transport.calls.compactMap { $0.request.subprotocols.first }.sorted()
        == ["0", "1", "2", "3", "4", "5", "6", "7"])
  }

  @Test("The mock transport records exact inputs and never retries a seeded rejection")
  func transportRecordsInputsWithoutRetrying() async throws {
    let url = try #require(URL(string: "wss://example.com/a%2Fb?q=%26"))
    let connection = ScriptedWebSocketConnection()
    let transport = MockWebSocketTransport(answers: [
      .init(
        result: .failure(
          WebSocketError(kind: .handshakeRejected, response: .init(status: .unauthorized)))),
      .init(result: .success(connection)),
    ])
    let request = WebSocketRequest(
      headers: [.authorization: "Bearer test"], subprotocols: ["v1"], url: url)
    let options = WebSocket.Options(maxPendingSendMessages: 3, sendFailurePolicy: .abortConnection)
    do {
      _ = try await transport.connect(request, options: options)
      Issue.record("The rejection was not returned.")
    } catch {
      #expect(error.response?.status.code == 401)
    }
    #expect(transport.calls.count == 1)
    #expect(try await transport.connect(request) === connection)
    #expect(transport.calls[0].options == options)
    #expect(transport.calls[0].request.headers[.authorization] == "Bearer test")
    #expect(transport.calls[0].request.subprotocols == ["v1"])
    #expect(transport.calls[0].request.url.absoluteString == "wss://example.com/a%2Fb?q=%26")
    do {
      _ = try await transport.connect(request)
      Issue.record("The exhausted transport returned a connection.")
    } catch {
      #expect(error.underlying as? WebSocketScriptFailure == .noScriptedOutcome)
    }
    #expect(transport.calls.count == 3)
  }
}
