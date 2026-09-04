// The failure belongs to a stub that exists only where URLSession's loading system does, so it
// compiles away with it.
#if canImport(Darwin)

import Foundation

/// A failure ``StubURLProtocol`` produced itself, which no live server or network reports.
///
/// Read it back with ``init(_:)``, not with a cast. The URL loading system rebuilds the error a
/// `URLProtocol` reports as a plain `NSError`, carrying the same domain and code but none of the
/// Swift value, so `error as? StubURLProtocolFailure` is always `nil` by the time a caller sees it:
///
/// ```swift
/// do {
///   _ = try await session.data(for: request)
///   Issue.record("The request should not have been answered.")
/// } catch {
///   #expect(StubURLProtocolFailure(error) == .noCannedResponse)
/// }
/// ```
///
/// ``MockTransport`` reports its own failures as ``MockTransportFailure``, so a caught error always
/// identifies which of the two produced it.
public enum StubURLProtocolFailure: Error, CustomNSError, Hashable, Sendable {
  /// The scripted status and header fields do not form a response the URL loading system accepts:
  /// a status outside the range `HTTPURLResponse` represents, or a request with no URL to
  /// attribute the response to.
  case invalidResponse

  /// A request arrived with no handler registered for its path and nothing left in the queue, or
  /// the script that would have answered it no longer exists.
  case noCannedResponse

  /// The domain the URL loading system stamps on this failure on its way back to the caller.
  public static var errorDomain: String { "HTTPTesting.StubURLProtocolFailure" }

  /// Creates a failure from the error a `URLSession` task reported, or `nil` when the error came
  /// from somewhere else.
  ///
  /// - Parameter error: The error a request failed with.
  public init?(_ error: some Error) {
    let bridged = error as NSError
    guard bridged.domain == Self.errorDomain else { return nil }
    switch bridged.code {
    case Self.invalidResponse.errorCode: self = .invalidResponse
    case Self.noCannedResponse.errorCode: self = .noCannedResponse
    default: return nil
    }
  }

  /// The code this failure carries into `NSError`, fixed per case so ``init(_:)`` reads it back.
  public var errorCode: Int {
    switch self {
    case .invalidResponse: 0
    case .noCannedResponse: 1
    }
  }
}

#endif
