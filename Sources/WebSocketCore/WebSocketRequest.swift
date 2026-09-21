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
  ///
  /// The opening-handshake policy requires `wss` when this value is present. Its credential
  /// replaces the configured header field, including removing that field when no token is held.
  public var authentication: Authentication?

  /// Additional handshake headers.
  ///
  /// The opening-handshake policy rejects transport-owned fields, including `Host`,
  /// `Connection`, `Upgrade`, framing fields and `Sec-WebSocket-*`. Explicit `Cookie` and
  /// `Origin` fields are allowed. Values are those already represented by `HTTPFields`.
  public var headers: HTTPFields

  /// Offered subprotocols in caller preference order.
  ///
  /// The opening-handshake policy requires distinct, nonempty HTTP tokens. Comparison is
  /// case-sensitive; order is preserved.
  public var subprotocols: [String]

  /// The destination URL, preserving its escaping.
  ///
  /// The opening-handshake policy requires an absolute `ws` or `wss` URL with a host,
  /// an optional port in `1...65535`, and no user information or fragment.
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
