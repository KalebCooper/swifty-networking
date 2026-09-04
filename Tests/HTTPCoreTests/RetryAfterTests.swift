import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

@Suite("RetryAfter.delay(in:)", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct RetryAfterTests {
  /// Values written from RFC 9110 10.2.3, `delay-seconds = 1*DIGIT`, and the wait each one means.
  static let deltaSeconds: [(value: String, expected: Duration)] = [
    ("0", .zero),
    ("2", .seconds(2)),
    ("007", .seconds(7)),
    ("120", .seconds(120)),
    (" 2", .seconds(2)),
    ("2 ", .seconds(2)),
    ("\t2\t", .seconds(2)),
    ("\(Int.max)", .seconds(Int.max)),
  ]

  /// Values the grammar does not accept as delta-seconds, an HTTP-date first.
  static let ignored: [String] = [
    "Wed, 21 Oct 2015 07:28:00 GMT",
    "Sunday, 06-Nov-94 08:49:37 GMT",
    "",
    " ",
    "-1",
    "+1",
    "1.5",
    "1 2",
    "2s",
    "soon",
    "99999999999999999999",
  ]

  @Test("A whole number of seconds is read as that wait", arguments: deltaSeconds)
  func deltaSecondsIsRead(value: String, expected: Duration) {
    #expect(RetryAfter.delay(in: [.retryAfter: value]) == expected)
  }

  @Test(
    "A date, a sign, a fraction, an empty value, and an overflow are ignored", arguments: ignored)
  func otherFormsAreIgnored(value: String) {
    #expect(RetryAfter.delay(in: [.retryAfter: value]) == nil)
  }

  @Test("A response without the field answers nil")
  func absentFieldAnswersNil() {
    #expect(RetryAfter.delay(in: [:]) == nil)
    #expect(RetryAfter.delay(in: [.contentType: "2"]) == nil)
  }

  @Test("A field the server repeated is ignored rather than read as one of its values")
  func repeatedFieldIsIgnored() {
    var headers: HTTPFields = [:]
    headers.append(HTTPField(name: .retryAfter, value: "1"))
    headers.append(HTTPField(name: .retryAfter, value: "2"))
    #expect(RetryAfter.delay(in: headers) == nil)
  }
}
