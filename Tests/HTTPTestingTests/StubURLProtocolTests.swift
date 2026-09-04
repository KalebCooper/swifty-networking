// `StubURLProtocol` exists only where URLSession's loading system does, so this suite compiles away
// on other platforms.
#if canImport(Darwin)

import Foundation
import HTTPTesting
import Synchronization
import Testing

/// A well-formed URL at `path`.
private func endpoint(_ path: String = "/v1/things") throws -> URL {
  try #require(URL(string: "https://example.com" + path))
}

/// A session whose every request `script` answers.
private func makeSession(_ script: StubURLProtocol.Script) -> URLSession {
  URLSession(configuration: script.makeSessionConfiguration())
}

/// A 200 whose body is `text`.
private func ok(_ text: String) -> StubURLProtocol.Answer {
  .response(body: Data(text.utf8), headers: [:], status: 200)
}

/// The body as a string.
private func text(_ data: Data) -> String {
  String(decoding: data, as: UTF8.self)
}

/// A `Mutex`-backed sink a handler can close over. `Mutex` is noncopyable and a closure capturing one
/// directly consumes it, so a reference type wraps it.
private final class Recorder<Value: Sendable>: Sendable {
  private let state = Mutex<[Value]>([])

  var values: [Value] { state.withLock { $0 } }

  func append(_ value: Value) {
    state.withLock { $0.append(value) }
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct StubURLProtocolAnswerTests {
  @Test func scriptedResponseReachesTheCaller() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script(answers: [
      .response(body: Data("hello".utf8), headers: ["X-Fixture": "1"], status: 200)
    ])
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    let (data, response) = try await session.data(for: URLRequest(url: url))

    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(http.value(forHTTPHeaderField: "X-Fixture") == "1")
    #expect(text(data) == "hello")
    #expect(script.requests.count == 1)
  }

  @Test(arguments: [200, 201, 204, 301, 400, 401, 404, 409, 429, 500, 503])
  func everyScriptedStatusArrivesUnchanged(status: Int) async throws {
    let url = try endpoint()
    let answer = StubURLProtocol.Answer.response(body: Data(), headers: [:], status: status)
    let script = StubURLProtocol.Script(answers: [answer])
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    let (_, response) = try await session.data(for: URLRequest(url: url))

    #expect((response as? HTTPURLResponse)?.statusCode == status)
    #expect(script.requests.count == 1)
  }

  @Test func queueAnswersInOrder() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script(answers: [ok("first"), ok("second")])
    script.enqueue(ok("third"))
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    var bodies: [String] = []
    for _ in 0..<3 {
      let (data, _) = try await session.data(for: URLRequest(url: url))
      bodies.append(text(data))
    }

    #expect(bodies == ["first", "second", "third"])
    #expect(script.requests.count == 3)
  }

  @Test func scriptedFailureSurfacesAsThatURLError() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script(answers: [.failure(code: .timedOut, failingURL: nil)])
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    do {
      _ = try await session.data(for: URLRequest(url: url))
      Issue.record("the request should have failed")
    } catch let error as URLError {
      #expect(error.code == .timedOut)
    }
    #expect(script.requests.count == 1)
  }

  @Test func scriptedFailureCarriesItsFailingURL() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script(answers: [.failure(code: .cannotFindHost, failingURL: url)])
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    do {
      _ = try await session.data(for: URLRequest(url: url))
      Issue.record("the request should have failed")
    } catch let error as URLError {
      #expect(error.code == .cannotFindHost)
      #expect(error.failingURL == url)
    }
    #expect(script.requests.count == 1)
  }

  @Test func anUnscriptedRequestFailsWithTheStubsOwnError() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script()
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    do {
      _ = try await session.data(for: URLRequest(url: url))
      Issue.record("the request should have failed")
    } catch {
      #expect(StubURLProtocolFailure(error) == .noCannedResponse)
    }
    #expect(script.requests.count == 1)
  }

  @Test func aDrainedQueueFailsTheNextRequest() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script(answers: [ok("only")])
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    let (data, _) = try await session.data(for: URLRequest(url: url))
    #expect(text(data) == "only")

    do {
      _ = try await session.data(for: URLRequest(url: url))
      Issue.record("the second request should have failed")
    } catch {
      #expect(StubURLProtocolFailure(error) == .noCannedResponse)
    }
    #expect(script.requests.count == 2)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct StubURLProtocolHandlerTests {
  @Test func aHandlerForThePathBeatsTheQueue() async throws {
    let things = try endpoint("/v1/things")
    let widgets = try endpoint("/v1/widgets")
    let script = StubURLProtocol.Script(answers: [ok("queued")])
    script.setHandler(forPath: "/v1/things") { _ in ok("handled") }
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    let (handled, _) = try await session.data(for: URLRequest(url: things))
    #expect(text(handled) == "handled")

    // The queue is untouched, so a request the handler does not claim still finds it.
    let (queued, _) = try await session.data(for: URLRequest(url: widgets))
    #expect(text(queued) == "queued")
  }

  @Test func aPathWithNoHandlerFallsToTheQueue() async throws {
    let things = try endpoint("/v1/things")
    let script = StubURLProtocol.Script(answers: [ok("queued")])
    script.setHandler(forPath: "/v1/widgets") { _ in ok("handled") }
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    let (data, _) = try await session.data(for: URLRequest(url: things))

    #expect(text(data) == "queued")
  }

  @Test func aHandlerForThePathAnswersARequestThatCarriesAQuery() async throws {
    let url = try endpoint("/v1/things?x=1")
    let script = StubURLProtocol.Script()
    script.setHandler(forPath: "/v1/things") { request in
      ok(request.url?.query() ?? "")
    }
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    let (data, _) = try await session.data(for: URLRequest(url: url))

    // The body is the query the handler was given, so this also shows the handler sees it.
    #expect(text(data) == "x=1")
  }

  @Test func aHandlerKeyCarryingAQueryDoesNotMatchAPlainPath() async throws {
    let plain = try endpoint("/v1/things")
    let queried = try endpoint("/v1/things?x=1")
    let script = StubURLProtocol.Script(answers: [ok("queued"), ok("queued")])
    script.setHandler(forPath: "/v1/things?x=1") { _ in ok("handled") }
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    let (first, _) = try await session.data(for: URLRequest(url: plain))
    #expect(text(first) == "queued")

    let (second, _) = try await session.data(for: URLRequest(url: queried))
    #expect(text(second) == "queued")
  }

  @Test func aHandlerSeesTheRequestAndAnswersEveryMatchingOne() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script()
    let seen = Recorder<String>()
    script.setHandler(forPath: "/v1/things") { request in
      seen.append(request.httpMethod ?? "")
      return ok("handled")
    }
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    for _ in 0..<3 {
      _ = try await session.data(for: URLRequest(url: url))
    }

    #expect(seen.values == ["GET", "GET", "GET"])
    #expect(script.requests.count == 3)
  }

  @Test func registeringAHandlerAgainReplacesIt() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script()
    script.setHandler(forPath: "/v1/things") { _ in ok("first") }
    script.setHandler(forPath: "/v1/things") { _ in ok("second") }
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    let (data, _) = try await session.data(for: URLRequest(url: url))

    #expect(text(data) == "second")
  }

  @Test func oneHandlerServesAConcurrentBurst() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script()
    script.setHandler(forPath: "/v1/things") { _ in ok("handled") }
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<8 {
        group.addTask {
          let (data, _) = try await session.data(for: URLRequest(url: url))
          return text(data)
        }
      }
      var bodies: [String] = []
      for try await body in group {
        bodies.append(body)
      }
      #expect(bodies == Array(repeating: "handled", count: 8))
    }

    #expect(script.requests.count == 8)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct StubURLProtocolLogTests {
  @Test func theLogRecordsMethodURLAndHeaderFields() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script(answers: [ok("done")])
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
    _ = try await session.data(for: request)

    let call = try #require(script.last)
    #expect(call.request.httpMethod == "DELETE")
    #expect(call.request.url == url)
    #expect(call.request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    #expect(call.request.value(forHTTPHeaderField: StubURLProtocol.tokenHeaderField) != nil)
    #expect(call.body == nil)
  }

  @Test func theLogRecordsABodySetAsData() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script(answers: [ok("done")])
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data(#"{"id":1}"#.utf8)
    _ = try await session.data(for: request)

    let call = try #require(script.last)
    #expect(call.body.map(text) == #"{"id":1}"#)
  }

  @Test func theLogRecordsABodySetAsAStream() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script(answers: [ok("done")])
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.httpBodyStream = InputStream(data: Data("streamed".utf8))
    _ = try await session.data(for: request)

    let call = try #require(script.last)
    #expect(call.body.map(text) == "streamed")
  }

  @Test func theLogRecordsAnUploadedBody() async throws {
    let url = try endpoint()
    let script = StubURLProtocol.Script(answers: [ok("done")])
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    _ = try await session.upload(for: request, from: Data("uploaded".utf8))

    let call = try #require(script.last)
    #expect(call.body.map(text) == "uploaded")
  }

  @Test func lastIsNilUntilARequestArrivesAndThenTheNewest() async throws {
    let things = try endpoint("/v1/things")
    let widgets = try endpoint("/v1/widgets")
    let script = StubURLProtocol.Script(answers: [ok("first"), ok("second")])
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    #expect(script.last == nil)

    _ = try await session.data(for: URLRequest(url: things))
    #expect(script.last?.request.url == things)

    _ = try await session.data(for: URLRequest(url: widgets))
    #expect(script.last?.request.url == widgets)
  }

  @Test func resetReturnsTheScriptToItsFreshlyConstructedState() async throws {
    let things = try endpoint("/v1/things")
    let widgets = try endpoint("/v1/widgets")
    let script = StubURLProtocol.Script(answers: [ok("queued")])
    script.setHandler(forPath: "/v1/widgets") { _ in ok("handled") }
    let session = makeSession(script)
    defer { session.finishTasksAndInvalidate() }

    _ = try await session.data(for: URLRequest(url: things))
    #expect(script.requests.count == 1)

    script.reset()

    #expect(script.requests.isEmpty)
    #expect(script.last == nil)
    do {
      _ = try await session.data(for: URLRequest(url: widgets))
      Issue.record("the cleared handler should not have answered")
    } catch {
      #expect(StubURLProtocolFailure(error) == .noCannedResponse)
    }
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct StubURLProtocolIsolationTests {
  @Test func twoScriptsCannotSeeEachOthersAnswers() async throws {
    let url = try endpoint()
    let one = StubURLProtocol.Script(answers: [ok("one")])
    let two = StubURLProtocol.Script(answers: [ok("two")])
    let sessionOne = makeSession(one)
    let sessionTwo = makeSession(two)
    defer {
      sessionOne.finishTasksAndInvalidate()
      sessionTwo.finishTasksAndInvalidate()
    }

    async let first = sessionOne.data(for: URLRequest(url: url))
    async let second = sessionTwo.data(for: URLRequest(url: url))
    let (dataOne, _) = try await first
    let (dataTwo, _) = try await second

    #expect(text(dataOne) == "one")
    #expect(text(dataTwo) == "two")
    #expect(one.requests.count == 1)
    #expect(two.requests.count == 1)
  }

  @Test func aRequestWithoutTheTokenIsNotThisStubsToAnswer() throws {
    let url = try endpoint()
    #expect(StubURLProtocol.canInit(with: URLRequest(url: url)) == false)

    var marked = URLRequest(url: url)
    marked.setValue("any", forHTTPHeaderField: StubURLProtocol.tokenHeaderField)
    #expect(StubURLProtocol.canInit(with: marked))
  }
}

#endif
