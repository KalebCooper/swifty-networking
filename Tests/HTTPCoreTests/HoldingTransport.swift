import HTTPCore
import HTTPTesting
import HTTPTypes

/// A transport that sleeps on the injected clock before forwarding each send to a ``MockTransport``.
/// A test releases a parked send with `waitForPendingSleep()` followed by `advanceAll()`.
final class HoldingTransport: Transport, Sendable {
  let clock: RecordingClock
  let inner: MockTransport

  init(clock: RecordingClock, inner: MockTransport) {
    self.clock = clock
    self.inner = inner
  }

  func send(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> Response
  {
    try await hold()
    return try await inner.send(request, body: body, options: options)
  }

  func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> StreamedResponse
  {
    try await hold()
    return try await inner.stream(request, body: body, options: options)
  }

  /// The one-second wait on the injected clock that parks a call until the test releases it.
  private func hold() async throws(TransportError) {
    do {
      try await Task.sleep(for: .seconds(1), tolerance: .zero, clock: clock)
    } catch {
      throw .transport(kind: .other, underlying: error)
    }
  }
}
