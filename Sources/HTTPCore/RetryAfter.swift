import HTTPTypes

/// The client's reading of a `Retry-After` response header field.
///
/// RFC 9110 10.2.3 allows two forms, a number of seconds and an HTTP-date. Only the first is read:
/// a date needs a wall clock to turn into a wait, and the client has none, so a date is treated as
/// no field at all and the backoff schedule applies.
package enum RetryAfter {
  /// Returns the wait a `Retry-After` field asks for, or `nil` when the field is absent or is not a
  /// number of seconds.
  ///
  /// The value is read as `delay-seconds = 1*DIGIT`, with the whitespace RFC 9110 allows around a
  /// field value removed first. So `"2"` is two seconds, `"0"` is no wait, and `"007"` is seven
  /// seconds; an HTTP-date, a sign, a fraction, and an empty value all answer `nil`, as does a
  /// header repeated on the response, since the wire types join repeated fields with a comma. So
  /// does a number of seconds that overflows `Int`: it is treated as absent rather than clamped.
  /// Any value that fits is returned as written, up to `Int.max` seconds; bounding the wait is the
  /// request's deadline's job.
  ///
  /// How the wait is served is the client's decision: a wait longer than what remains of the
  /// request's deadline is cut short by that deadline, and the request fails with
  /// ``TransportFailureKind/timedOut``.
  ///
  /// - Parameter headers: The response header fields to read the `Retry-After` field from.
  /// - Returns: The wait, or `nil` when there is no delta-seconds value to read.
  package static func delay(in headers: HTTPFields) -> Duration? {
    guard let value = headers[.retryAfter] else { return nil }
    let bytes = value.utf8
    let space = UInt8(ascii: " ")
    let tab = UInt8(ascii: "\t")
    var start = bytes.startIndex
    var end = bytes.endIndex
    while start < end, bytes[start] == space || bytes[start] == tab {
      start = bytes.index(after: start)
    }
    while start < end,
      bytes[bytes.index(before: end)] == space
        || bytes[bytes.index(before: end)] == tab
    {
      end = bytes.index(before: end)
    }
    guard start < end else { return nil }

    let zero = UInt8(ascii: "0")
    let nine = UInt8(ascii: "9")
    var seconds = 0
    for byte in bytes[start..<end] {
      guard zero <= byte, byte <= nine else { return nil }
      let (scaled, scaleOverflow) = seconds.multipliedReportingOverflow(by: 10)
      let (total, addOverflow) = scaled.addingReportingOverflow(Int(byte - zero))
      guard !scaleOverflow, !addOverflow else { return nil }
      seconds = total
    }
    return .seconds(seconds)
  }
}
