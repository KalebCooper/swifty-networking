// `Data` and `URL` are the only Foundation types this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The request body as a transport receives it.
///
/// ``HTTPClient`` resolves a ``RequestBody`` into one of these before it calls the transport. A
/// ``RequestBody/json(_:)`` value is encoded into ``bytes(_:)``, a ``RequestBody/form(_:)`` and a
/// ``RequestBody/multipart(_:)`` value are each rendered into ``bytes(_:)`` as well,
/// ``RequestBody/bytes(_:contentType:)`` keeps its bytes, ``RequestBody/file(_:contentType:)``
/// becomes ``file(_:)`` with the same URL, and ``RequestBody/none`` is ``none``. The media type
/// never travels here: by the time the transport is called it is a `Content-Type` header field on
/// the request.
///
/// Only a transport switches over this type. A body kind that arrives later is a new case, and the
/// transport that has to learn to send it is the code that switches.
///
/// ```swift
/// switch body {
/// case .bytes(let data):
///   urlRequest.httpBody = data
/// case .file(let url):
///   urlRequest.httpBodyStream = InputStream(url: url)
/// case .none:
///   break
/// }
/// ```
public enum TransportBody: Hashable, Sendable {
  /// Bytes already in memory, sent as they are.
  case bytes(Data)

  /// A file the transport reads as it sends, so the bytes never pass through the request.
  case file(URL)

  /// No body.
  case none
}
