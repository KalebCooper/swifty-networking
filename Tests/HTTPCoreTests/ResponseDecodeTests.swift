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

/// A value whose field name only matches the body under a decoder configured for it.
private struct SnakePayload: Codable, Equatable {
  let theText: String
}

/// A model that is not `Sendable`, decoded to prove the value crosses back as `sending`.
private final class MutablePayload: Decodable {
  var text: String
}

/// A payload whose encoded form is exactly `bytes` long.
private func payload(ofBytes bytes: Int) -> (body: Data, value: Payload) {
  let text = String(repeating: "a", count: bytes - #"{"text":""#.utf8.count - #""}"#.utf8.count)
  return (Data(#"{"text":"\#(text)"}"#.utf8), Payload(text: text))
}

/// The body size at which a response changes how it decodes.
private let threshold = 16 * 1024

@Suite("Response decoding", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct ResponseDecodeTests {
  @Test(
    "a body decodes to the same value on either side of the size that changes how it is decoded",
    arguments: [64, threshold, threshold + 1, 4 * threshold])
  func decodesWhateverTheSize(bytes: Int) async throws {
    let expected = payload(ofBytes: bytes)
    let response = Response.ok(json: expected.body)

    let decoded = try await response.decode(Payload.self, with: JSONDecoder())

    #expect(expected.body.count == bytes)
    #expect(decoded == expected.value)
  }

  @Test(
    "a body that is not what the caller asked for fails to decode, whichever way it was decoded",
    arguments: [64, 4 * threshold])
  func malformedBodyFailsToDecode(bytes: Int) async throws {
    let truncated = payload(ofBytes: bytes).body.dropLast(2)
    let response = Response.ok(json: Data(truncated))

    let error = await failure { try await response.decode(Payload.self, with: JSONDecoder()) }

    #expect(error?.underlying is DecodingError)
    guard case .decode? = error else {
      Issue.record("expected a decode failure, got \(String(describing: error))")
      return
    }
  }

  @Test("an empty body is no value at all, so it fails to decode rather than answering one")
  func emptyBodyFailsToDecode() async throws {
    let response = Response.empty()

    let error = await failure { try await response.decode(Payload.self, with: JSONDecoder()) }

    #expect(error?.underlying is DecodingError)
    guard case .decode? = error else {
      Issue.record("expected a decode failure, got \(String(describing: error))")
      return
    }
  }

  @Test("the type is inferred from the context when it is left out")
  func typeIsInferred() async throws {
    let expected = payload(ofBytes: 64)
    let response = Response.ok(json: expected.body)

    let decoded: Payload = try await response.decode(with: JSONDecoder())

    #expect(decoded == expected.value)
  }

  @Test("the decoder the caller passes is the one that reads the body")
  func callersDecoderReadsTheBody() async throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let response = Response.ok(json: Data(#"{"the_text":"snake"}"#.utf8))

    let decoded = try await response.decode(SnakePayload.self, with: decoder)

    #expect(decoded == SnakePayload(theText: "snake"))
  }

  @Test("the status is not consulted, so an error body decodes as a successful one does")
  func statusIsNotConsulted() async throws {
    let expected = payload(ofBytes: 64)
    let response = Response.json(expected.body, status: .badRequest)

    let decoded = try await response.decode(Payload.self, with: JSONDecoder())

    #expect(decoded == expected.value)
  }

  @Test(
    "a decoded model need not be Sendable, whichever way it was decoded",
    arguments: [64, 4 * threshold])
  func decodedModelNeedNotBeSendable(bytes: Int) async throws {
    let expected = payload(ofBytes: bytes)
    let response = Response.ok(json: expected.body)

    let decoded = try await response.decode(MutablePayload.self, with: JSONDecoder())

    #expect(decoded.text == expected.value.text)
  }

  @Test("a response built by hand decodes")
  func handBuiltResponseDecodes() async throws {
    let expected = payload(ofBytes: 64)
    let response = Response(
      body: expected.body,
      headers: [.contentType: "application/json"],
      status: .ok)

    let decoded = try await response.decode(Payload.self, with: JSONDecoder())

    #expect(decoded == expected.value)
  }
}
