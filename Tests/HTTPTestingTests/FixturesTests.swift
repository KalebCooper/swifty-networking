import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A value whose fields are declared out of alphabetical order.
private struct Sample: Codable, Equatable {
  let zebra: Int
  let apple: String
}

@Suite("Fixtures.json / jsonObject", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct FixturesJSONTests {
  @Test("json(_:) sorts keys regardless of declaration order")
  func jsonSortsKeys() throws {
    let bytes = try Fixtures.json(Sample(zebra: 1, apple: "a"))
    #expect(String(decoding: bytes, as: UTF8.self) == #"{"apple":"a","zebra":1}"#)
  }

  @Test("json(_:) round-trips through JSONDecoder")
  func jsonRoundTrips() throws {
    let sample = Sample(zebra: 9, apple: "value")
    let bytes = try Fixtures.json(sample)
    let decoded = try JSONDecoder().decode(Sample.self, from: bytes)
    #expect(decoded == sample)
  }

  @Test("jsonObject(_:) writes pairs as a flat JSON object, in the order given")
  func jsonObjectWritesPairsInOrder() {
    let bytes = Fixtures.jsonObject(["b": "2", "a": "1"])
    #expect(String(decoding: bytes, as: UTF8.self) == #"{"b":"2","a":"1"}"#)
  }

  @Test("jsonObject(_:) escapes quotes and backslashes in values")
  func jsonObjectEscapesValues() throws {
    let bytes = Fixtures.jsonObject(["message": #"say "hi" \ ok"#])
    let decoded = try JSONDecoder().decode([String: String].self, from: bytes)
    #expect(decoded["message"] == #"say "hi" \ ok"#)
  }

  @Test("jsonObject(_:) with no pairs is an empty object")
  func jsonObjectEmpty() {
    let bytes = Fixtures.jsonObject([:])
    #expect(String(decoding: bytes, as: UTF8.self) == "{}")
  }
}

@Suite("Response.empty / .json / .ok(json:) / .text", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct ResponseFixturesTests {
  @Test("empty() defaults to 204 with a zero-length body and no headers")
  func emptyDefaults() {
    let response = Response.empty()
    #expect(response.status == .noContent)
    #expect(response.body.isEmpty)
    #expect(response.headers.isEmpty)
    #expect(response.contentTypeSniff() == .empty)
  }

  @Test("empty(headers:status:) carries the given status and headers through")
  func emptyCarriesArguments() {
    let response = Response.empty(headers: [.contentType: "text/plain"], status: .ok)
    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "text/plain")
    #expect(response.body.isEmpty)
  }

  @Test("json(_:headers:status:) adds Content-Type when the caller has not set one")
  func jsonAddsContentTypeWhenAbsent() {
    let body = Fixtures.jsonObject(["ok": "true"])
    let response = Response.json(body, status: .accepted)
    #expect(response.headers[.contentType] == "application/json")
    #expect(response.status == .accepted)
    #expect(response.body == body)
    #expect(response.contentTypeSniff() == .json)
  }

  @Test("json(_:headers:status:) keeps a Content-Type the caller already set")
  func jsonKeepsContentTypeWhenPresent() {
    let body = Fixtures.jsonObject(["ok": "true"])
    let response = Response.json(
      body, headers: [.contentType: "application/vnd.custom+json"], status: .accepted)
    #expect(response.headers[.contentType] == "application/vnd.custom+json")
  }

  @Test("ok(headers:json:) is always 200 and adds Content-Type when the caller has not set one")
  func okAddsContentTypeWhenAbsent() {
    let body = Fixtures.jsonObject(["ok": "true"])
    let response = Response.ok(json: body)
    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "application/json")
    #expect(response.body == body)
    #expect(response.contentTypeSniff() == .json)
  }

  @Test("ok(headers:json:) keeps a Content-Type the caller already set")
  func okKeepsContentTypeWhenPresent() {
    let body = Fixtures.jsonObject(["ok": "true"])
    let response = Response.ok(headers: [.contentType: "application/vnd.custom+json"], json: body)
    #expect(response.headers[.contentType] == "application/vnd.custom+json")
  }

  @Test("text(_:) defaults to a 200 tagged text/plain; charset=utf-8")
  func textDefaults() {
    let response = Response.text("hello")
    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "text/plain; charset=utf-8")
    #expect(String(decoding: response.body, as: UTF8.self) == "hello")
    #expect(response.contentTypeSniff() == .unknown)
  }

  @Test("text(_:) encodes non-ASCII text as UTF-8")
  func textEncodesNonASCII() {
    let response = Response.text("café ☕️")
    #expect(response.body == Data("café ☕️".utf8))
    #expect(String(decoding: response.body, as: UTF8.self) == "café ☕️")
  }

  @Test("text(_:headers:status:) keeps an already-set Content-Type and a given status")
  func textCarriesArguments() {
    let response = Response.text(
      "plain", headers: [.contentType: "text/markdown"], status: .accepted)
    #expect(response.headers[.contentType] == "text/markdown")
    #expect(response.status == .accepted)
  }
}
