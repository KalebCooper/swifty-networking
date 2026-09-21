#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPCore
import HTTPTypes

/// The inputs for an outbound WebSocket handshake.
///
/// This value stores inputs without validating them or obtaining credentials.
/// Accepted server connections do not use an outbound request.
public struct WebSocketRequest: Sendable {
  /// The shared authentication value, without invoking its credential provider.
  public var authentication: Authentication?

  /// Additional handshake headers.
  public var headers: HTTPFields

  /// Offered subprotocols in caller preference order.
  public var subprotocols: [String]

  /// The destination URL, preserving its escaping.
  public var url: URL

  /// Creates a request without performing network or authentication work.
  public init(
    authentication: Authentication? = nil,
    headers: HTTPFields = [:],
    subprotocols: [String] = [],
    url: URL
  ) {
    self.authentication = authentication
    self.headers = headers
    self.subprotocols = subprotocols
    self.url = url
  }
}
