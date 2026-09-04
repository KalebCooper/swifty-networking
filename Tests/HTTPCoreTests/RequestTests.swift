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

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct RequestTests {
  @Test("Only the path is required; every other field takes its documented default")
  func defaultsApply() {
    let request = Request(path: "/users")

    #expect(request.path == "/users")
    #expect(request.method == .get)
    #expect(request.headers.isEmpty)
    #expect(request.query.isEmpty)
    guard case .none = request.body else {
      Issue.record("default body should be .none, got \(request.body)")
      return
    }
  }

  @Test("The memberwise initializer stores every field")
  func memberwiseStoresFields() throws {
    let payload = Data("{}".utf8)
    let options = RequestOptions(
      cachePolicy: .ignoreCache, coalescingKey: "users", requiresAuth: false
    )
    let request = Request(
      body: .bytes(payload, contentType: "application/json"),
      headers: [.accept: "application/json"],
      method: .post,
      options: options,
      path: "/users",
      query: [QueryItem(name: "page", value: "2")]
    )

    #expect(request.method == .post)
    #expect(request.headers[.accept] == "application/json")
    #expect(request.options.cachePolicy == .ignoreCache)
    #expect(request.options.coalescingKey == "users")
    #expect(request.options.requiresAuth == false)
    #expect(request.query == [QueryItem(name: "page", value: "2")])
    guard case .bytes(let bytes, let contentType) = request.body else {
      Issue.record("body should be .bytes, got \(request.body)")
      return
    }
    #expect(bytes == payload)
    #expect(contentType == "application/json")
  }

  @Test("A JSON body carries the value for the client's encoder")
  func jsonBodyCarriesValue() throws {
    struct Payload: Encodable, Sendable, Equatable {
      let name: String
    }
    let request = Request(body: .json(Payload(name: "a")), method: .put, path: "/x")

    guard case .json(let value) = request.body else {
      Issue.record("body should be .json, got \(request.body)")
      return
    }
    #expect(value as? Payload == Payload(name: "a"))
  }

  @Test("A request is a mutable value")
  func requestIsMutableValue() {
    var request = Request(path: "/a")
    let original = request

    request.path = "/b"
    request.query.append(QueryItem(name: "k", value: "v"))
    request.headers[.authorization] = "Bearer t"

    #expect(request.path == "/b")
    #expect(request.query.percentEncoded == "k=v")
    #expect(request.headers[.authorization] == "Bearer t")
    #expect(original.path == "/a")
    #expect(original.query.isEmpty)
    #expect(original.headers.isEmpty)
  }

  @Test("The query renders through the same encoder as a bare item collection")
  func queryRendersEncoded() {
    let request = Request(
      path: "/search",
      query: [QueryItem(name: "q", value: "a b+c"), QueryItem(name: "lang", value: "日本")]
    )
    #expect(request.query.percentEncoded == "q=a%20b%2Bc&lang=%E6%97%A5%E6%9C%AC")
  }

  @Test("Request options default to their no-op values")
  func optionsDefaultToNoOp() {
    let options = RequestOptions()
    #expect(options.cachePolicy == nil)
    #expect(options.coalescingKey == nil)
    #expect(options.redirectPolicy == nil)
    #expect(options.requiresAuth == true)
    #expect(options.retryPolicy == nil)
    #expect(options.timeout == nil)
  }

  @Test("A request carries its own retry policy when one is set")
  func optionsCarryARetryPolicy() throws {
    var options = RequestOptions()
    options.retryPolicy = RetryPolicy(backoff: .zero, maxAttempts: 5)
    #expect(options.retryPolicy?.maxAttempts == 5)

    let overridden = RequestOptions(
      retryPolicy: RetryPolicy(
        backoff: BackoffSchedule(delays: [.milliseconds(10)]), maxAttempts: 2)
    )
    let policy = try #require(overridden.retryPolicy)
    #expect(policy.maxAttempts == 2)
    #expect(policy.backoff.delay(forAttempt: 1) == .milliseconds(10))
    let timeout = FailedAttempt(
      attempt: 1, elapsed: .zero, failure: .transport(kind: .timedOut, underlying: nil))
    #expect(policy.retryable(timeout))
  }

  @Test("A response is a value keyed on status, headers, and body")
  func responseIsValue() {
    let body = Data("ok".utf8)
    let response = Response(body: body, headers: [.contentType: "text/plain"], status: .ok)
    let same = Response(body: body, headers: [.contentType: "text/plain"], status: .ok)

    #expect(response == same)
    #expect(response.status.code == 200)
    #expect(response.headers[.contentType] == "text/plain")
    #expect(response.body == body)
    #expect(Response(status: .notFound).body.isEmpty)
    #expect(Response(status: .notFound) != response)
  }

  @Test("Every wire type crosses isolation boundaries freely")
  func wireTypesAreSendable() {
    requireSendable(CachePolicy.self)
    requireSendable(QueryItem.self)
    requireSendable(Request.self)
    requireSendable(RequestBody.self)
    requireSendable(RequestOptions.self)
    requireSendable(Response.self)
  }
}
