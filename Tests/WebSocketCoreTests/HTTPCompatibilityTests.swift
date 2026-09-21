#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

@Suite("HTTP transport compatibility", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct HTTPCompatibilityTests {
  private struct StreamOnlyTransport: Transport {
    func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
      async throws(TransportError) -> StreamedResponse
    {
      let chunks = AsyncStream<Data> { continuation in
        continuation.yield(Data([1, 2, 3]))
        continuation.finish()
      }
      return StreamedResponse(body: StreamedBody(chunks), headers: [:], status: .ok)
    }
  }

  @Test("An HTTP conformer still supplies only stream and inherits buffered send")
  func streamOnlyConformerRetainsBufferedSend() async throws {
    let request = HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/")
    let response = try await StreamOnlyTransport().send(request, body: .none, options: .init())
    #expect(response.body == Data([1, 2, 3]))
    #expect(response.status == .ok)
  }
}
