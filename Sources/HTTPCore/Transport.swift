// `Data` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTypes

/// A type that sends a fully resolved request and returns the server's response.
///
/// A transport is the boundary between ``HTTPClient`` and whatever moves the bytes. The request
/// arrives absolute, with scheme, authority, path, and query already joined and credentials already
/// attached, and the response comes back exactly as the server sent it. Every policy, including the
/// base-URL join, status interpretation, decoding, and retrying, lives in the client.
///
/// One method is required, ``stream(_:body:options:)``, which returns the response as soon as its
/// status and header fields are known and delivers the body as chunks. ``send(_:body:options:)``
/// has a default that drains that body into one `Data`, so a transport that streams buffers for
/// free; a transport with a cheaper buffered path of its own, such as `URLSessionTransport`,
/// overrides it.
///
/// The body arrives as a ``TransportBody``, already encoded and named by a `Content-Type` field on
/// the request, and the settings the transport itself acts on arrive as ``TransportOptions``.
///
/// ```swift
/// struct EchoTransport: Transport {
///   func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
///     async throws(TransportError) -> StreamedResponse
///   {
///     let chunks = AsyncStream<Data> { continuation in
///       if case .bytes(let data) = body { continuation.yield(data) }
///       continuation.finish()
///     }
///     return StreamedResponse(body: StreamedBody(chunks), headers: [:], status: .ok)
///   }
/// }
/// ```
///
/// ## Conforming to the Protocol
///
/// - A non-2xx status is a response, not an error. Return it and let the client decide what it
///   means, including deciding to discard the body unread.
/// - Throw a ``TransportError`` only for a request that produced no response: the transport's own
///   failure mapped onto ``TransportError/transport(kind:underlying:)``, or
///   ``TransportError/cancelled`` when the calling task was cancelled first. A failure after the
///   response is available reaches the caller through the body sequence, as its ``TransportError``
///   failure. A transport never throws ``TransportError/decode(underlying:)`` or
///   ``TransportError/encode(underlying:)``, because it sees only bytes.
/// - A `3xx` status is returned like any other, never followed. Whether to send the request again
///   to the `Location` it names is ``HTTPClient/redirectPolicy``'s decision, and a transport that
///   followed on its own would hide every hop from that policy and from the observer.
/// - Discarding the body without reading it cancels whatever is still fetching it. A caller that
///   throws on the status, or replays the request after a `401`, leaves a sequence it never
///   started, and nothing keeps running behind it.
///
/// ## Isolation
///
/// Both methods run on the caller's actor until they truly suspend. The package builds with
/// `NonisolatedNonsendingByDefault`, so each requirement is `nonisolated(nonsending)` with no
/// annotation, and a `MainActor` caller pays no hop out and none back. Write a plain `func` to
/// inherit that behaviour, and do not mark the implementation `@concurrent`, which reintroduces the
/// hop on every request.
///
/// A conformer is never an `actor`. An actor cannot honour caller isolation: every call would hop
/// onto the actor and back, and everything the transport touches would become async. Keep shared
/// state, such as a connection pool, a cookie jar, or a mock transport's request log, in a `Mutex`
/// inside a `struct` or a `final class`.
///
/// The body sequence is `Sendable`, so a response can cross isolation whole. Its iterator is not,
/// and is in exclusive use by whichever task reads it.
public protocol Transport: Sendable {
  /// Sends one request and returns the server's complete response.
  ///
  /// - Parameters:
  ///   - request: The absolute request, with credentials and default header fields already applied.
  ///   - body: The body to send, or ``TransportBody/none`` for a body-less request.
  ///   - options: The settings this transport honours for the request.
  /// - Returns: The response as received, its body whole; a non-success status is returned, not
  ///   thrown.
  /// - Throws: A ``TransportError`` when the request produced no response, or when its body failed
  ///   before it ended.
  func send(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> Response

  /// Sends one request and returns the server's response with its body still arriving.
  ///
  /// - Parameters:
  ///   - request: The absolute request, with credentials and default header fields already applied.
  ///   - body: The body to send, or ``TransportBody/none`` for a body-less request.
  ///   - options: The settings this transport honours for the request.
  /// - Returns: The status and header fields as received, and the response body as a sequence of
  ///   chunks; a non-success status is returned, not thrown.
  /// - Throws: A ``TransportError`` when the request produced no response at all.
  func stream(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> StreamedResponse
}

extension Transport {
  /// Sends one request through ``stream(_:body:options:)`` and drains every chunk into one body.
  ///
  /// The chunks are appended in the order the body delivers them, and the status and header fields
  /// are the streamed response's own. A failure the body reports part-way through is thrown from
  /// here, after the chunks before it have been discarded, so a caller sees either a complete
  /// response or one error.
  ///
  /// ```swift
  /// let response = try await transport.send(request, body: .none, options: TransportOptions())
  /// print(response.status.code, response.body.count)
  /// ```
  ///
  /// - Parameters:
  ///   - request: The absolute request, with credentials and default header fields already applied.
  ///   - body: The body to send, or ``TransportBody/none`` for a body-less request.
  ///   - options: The settings this transport honours for the request.
  /// - Returns: The response as received, its body whole.
  /// - Throws: A ``TransportError`` when the request produced no response, or when its body failed
  ///   before it ended.
  public func send(_ request: HTTPRequest, body: TransportBody, options: TransportOptions)
    async throws(TransportError) -> Response
  {
    let response = try await stream(request, body: body, options: options)
    var collected = Data()
    for try await chunk in response.body {
      collected.append(chunk)
    }
    return Response(body: collected, headers: response.headers, status: response.status)
  }
}
