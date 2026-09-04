import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The value these tests decode. Its one field makes the encoded size a function of that field.
private struct Payload: Codable, Equatable {
  let text: String
}

/// A client over `MockTransport` and `RecordingClock`, defaulted apart from the observer.
private func makeClient(
  observer: RecordingObserver? = nil,
  transport: MockTransport
) -> HTTPClient {
  HTTPClient(
    baseURL: URL.fixture("https://api.example.com"),
    clock: RecordingClock(),
    observer: observer,
    transport: transport
  )
}

/// A payload whose encoded form is exactly `bytes` long.
private func payload(ofBytes bytes: Int) -> (body: Data, value: Payload) {
  let text = String(repeating: "a", count: bytes - #"{"text":""#.utf8.count - #""}"#.utf8.count)
  return (Data(#"{"text":"\#(text)"}"#.utf8), Payload(text: text))
}

/// The body size at which the client changes how it decodes.
private let threshold = 16 * 1024

private let path = "/people/1"
private let request = Request(path: path)

@Suite("HTTPClient decoding", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPClientDecodeTests {
  @Test(
    "a body decodes to the same value on either side of the size that changes how it is decoded",
    arguments: [64, threshold, threshold + 1, 4 * threshold])
  func decodesWhateverTheSize(bytes: Int) async throws {
    let expected = payload(ofBytes: bytes)
    let transport = MockTransport(results: [.success(.ok(json: expected.body))])
    let client = makeClient(transport: transport)

    let decoded: Payload = try await client.execute(request)

    #expect(expected.body.count == bytes)
    #expect(decoded == expected.value)
  }

  @Test(
    "a body that is not what the caller asked for fails to decode, whichever way it was decoded",
    arguments: [64, 4 * threshold])
  func malformedBodyFailsToDecode(bytes: Int) async throws {
    let truncated = payload(ofBytes: bytes).body.dropLast(2)
    let transport = MockTransport(results: [.success(.ok(json: Data(truncated)))])
    let client = makeClient(transport: transport)

    let error = await failure { try await client.execute(request) as Payload }

    #expect(error?.underlying is DecodingError)
    guard case .decode? = error else {
      Issue.record("expected a decode failure, got \(String(describing: error))")
      return
    }
  }

  @Test("a decode failure is the caller's alone: the observer saw a response, and nothing after it")
  func decodeFailureIsNotAnObserverEvent() async throws {
    let observer = RecordingObserver()
    let transport = MockTransport(results: [.success(.ok(json: Data(#"{"nope":1}"#.utf8)))])
    let client = makeClient(observer: observer, transport: transport)

    let error = await failure { try await client.execute(request) as Payload }

    guard case .decode? = error else {
      Issue.record("expected a decode failure, got \(String(describing: error))")
      return
    }
    #expect(observer.events.count == 2)
    guard case .received(let received)? = observer.last else {
      Issue.record("expected the last event to be the response")
      return
    }
    #expect(received.status == .ok)
  }

  @Test(
    "a decoded body arrives with the exact header fields and status the transport answered with",
    arguments: [64, threshold, threshold + 1, 4 * threshold])
  func decodingKeepsHeadersAndStatus(bytes: Int) async throws {
    let expected = payload(ofBytes: bytes)
    let seeded = Response.json(expected.body, headers: [.eTag: "\"v7\""], status: .created)
    let transport = MockTransport(results: [.success(seeded)])
    let client = makeClient(transport: transport)

    let decoded: DecodedResponse<Payload> = try await client.execute(request)

    #expect(expected.body.count == bytes)
    #expect(decoded.value == expected.value)
    #expect(decoded.headers == seeded.headers)
    #expect(decoded.headers[.eTag] == "\"v7\"")
    #expect(decoded.headers[.contentType] == "application/json")
    #expect(decoded.status == .created)
  }

  @Test("a body the caller did not ask for is a decode failure, headers or not")
  func headerCarryingDecodeFailure() async throws {
    let transport = MockTransport(results: [.success(.ok(json: Data(#"{"nope":1}"#.utf8)))])
    let client = makeClient(transport: transport)

    let error = await failure {
      try await client.execute(request) as DecodedResponse<Payload>
    }

    #expect(error?.underlying is DecodingError)
    guard case .decode? = error else {
      Issue.record("expected a decode failure, got \(String(describing: error))")
      return
    }
  }

  @Test("a non-2xx throws the status failure rather than answering a decoded response")
  func headerCarryingNonSuccessThrows() async throws {
    let body = Fixtures.jsonObject(["error": "nope"])
    let seeded = Response.json(body, headers: [.retryAfter: "30"], status: .badRequest)
    let transport = MockTransport(results: [.success(seeded)])
    let client = makeClient(transport: transport)

    let error = await failure {
      try await client.execute(request) as DecodedResponse<Payload>
    }

    guard case .httpStatus(body: let thrownBody, code: let code, headers: let headers) = error
    else {
      Issue.record("expected httpStatus, got \(String(describing: error))")
      return
    }
    #expect(code == HTTPResponse.Status.badRequest.code)
    #expect(thrownBody == body)
    #expect(headers[.retryAfter] == "30")
  }

  @Test("an entry point that decodes nothing reads no body, however large it is")
  func undecodedBodiesAreNotRead() async throws {
    let large = payload(ofBytes: 4 * threshold)
    let transport = MockTransport(results: [
      .success(.ok(json: large.body)), .success(.ok(json: large.body)),
    ])
    let client = makeClient(transport: transport)

    let raw = try await client.execute(request) as Response
    try await client.executeExpectingNoContent(request)

    #expect(raw.body == large.body)
  }

  @Test("the type a call is annotated with decides which of the three execute(_:) overloads runs")
  func annotationPicksTheOverload() async throws {
    let expected = payload(ofBytes: 64)
    let seeded = Response.json(expected.body, headers: [.eTag: "\"v7\""], status: .accepted)
    let transport = MockTransport(results: [.success(seeded), .success(seeded), .success(seeded)])
    let client = makeClient(transport: transport)

    let value: Payload = try await client.execute(request)
    let decoded: DecodedResponse<Payload> = try await client.execute(request)
    let raw: Response = try await client.execute(request)

    #expect(value == expected.value)
    #expect(decoded.value == expected.value)
    #expect(decoded.headers[.eTag] == "\"v7\"")
    #expect(decoded.status == .accepted)
    #expect(raw.body == expected.body)
    #expect(raw.status == .accepted)
    #expect(transport.requests.count == 3)
  }

  @Test("a discarded result still resolves to the one overload that decodes nothing")
  func discardedResultTakesTheResponseOverload() async throws {
    // Not a Payload, and no annotation says what to decode: a call that reached either decoding
    // overload would fail to compile or fail to decode rather than pass.
    let transport = MockTransport(results: [.success(.ok(json: Data(#"{"nope":1}"#.utf8)))])
    let client = makeClient(transport: transport)

    _ = try await client.execute(request)

    #expect(transport.requests.count == 1)
  }
}
