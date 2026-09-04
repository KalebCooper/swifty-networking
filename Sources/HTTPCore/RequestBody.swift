// `Data` and `URL` are the only Foundation types this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The payload a request carries.
///
/// The encoding decision is deferred to the moment of sending, so every JSON body a client sends is
/// produced by that client's own encoder. One request type with a body member is what keeps
/// ``HTTPClient`` to a single `execute` entry point per result shape.
///
/// The body also names the request's `Content-Type` when nothing else has: `application/json` for
/// ``json(_:)``, `application/x-www-form-urlencoded` for ``form(_:)``, `multipart/form-data` with
/// the form's boundary for ``multipart(_:)``, the stated type for ``bytes(_:contentType:)`` and
/// ``file(_:contentType:)``, and none at all for ``none``. A field the client's default header
/// fields or the request itself carries is left as you wrote it, with one exception:
/// ``multipart(_:)`` replaces it, because the boundary belongs to the media type and the form mints
/// it, so a field written by hand cannot name the body that follows.
///
/// ```swift
/// Request(body: .json(SignUp(email: "person@example.com")), method: .post, path: "/profiles")
/// Request(body: .form([QueryItem(name: "vote", value: "yes")]), method: .post, path: "/votes")
/// Request(body: .multipart(form), method: .post, path: "/photos")
/// Request(body: .bytes(pngData, contentType: "image/png"), method: .put, path: "/avatar")
/// Request(body: .file(videoURL, contentType: "video/mp4"), method: .put, path: "/recording")
/// Request(method: .delete, path: "/session")
/// ```
public enum RequestBody: Sendable {
  /// Pre-encoded bytes and the media type that describes them; both are sent verbatim.
  case bytes(Data, contentType: String)

  /// A file the transport reads as it sends, and the media type that describes it.
  ///
  /// The bytes never pass through the request: the client hands the URL to the transport as
  /// ``TransportBody/file(_:)`` and the transport streams the file onto the wire.
  case file(URL, contentType: String)

  /// Name and value pairs sent as an `application/x-www-form-urlencoded` body.
  ///
  /// The pairs are encoded at send time by the rule ``QueryItem/percentEncoded`` states, with one
  /// difference: a space is `+` rather than `%20`, and a literal `+` stays `%2B`, so a form decoder
  /// cannot read one as the other. Two spellings differ from the WHATWG URL standard's
  /// `application/x-www-form-urlencoded` serializer, which sends `~` as `%7E` and `*` as itself:
  /// here `~` is sent literally and `*` as `%2A`, and a decoder reads either pair of spellings back
  /// as the characters themselves. A `nil` value sends its name alone with no `=`, which a form
  /// parser reads as an empty value rather than as a missing one, so nothing distinguishes it from
  /// `""` once it is on the wire. The pairs are joined with `&` in the order given, duplicates kept.
  ///
  /// The body sets `Content-Type: application/x-www-form-urlencoded` unless the request or the
  /// client's default header fields already carry that field, which is left as you wrote it.
  ///
  /// ```swift
  /// try await client.executeExpectingNoContent(
  ///   Request(
  ///     body: .form([
  ///       QueryItem(name: "grant_type", value: "refresh_token"),
  ///       QueryItem(name: "refresh_token", value: token),
  ///     ]),
  ///     method: .post,
  ///     path: "/oauth/token"
  ///   )
  /// )
  /// ```
  case form([QueryItem])

  /// A value the client encodes as JSON with its configured encoder at send time.
  case json(any Encodable & Sendable)

  /// Text fields and files sent as a `multipart/form-data` body.
  ///
  /// The form is already encoded: it framed each part as it was appended, and resolving the request
  /// adds the closing delimiter. Every byte a part carries is held in memory, so a large upload
  /// belongs in ``file(_:contentType:)``, which the transport reads from disk as it sends.
  ///
  /// The body sets `Content-Type: multipart/form-data` naming the form's
  /// ``MultipartForm/boundary``, and here the body wins: a `Content-Type` the request or the
  /// client's default header fields carry is replaced rather than kept, because the form mints the
  /// boundary at the moment it is built and a field written by hand cannot name it. Every other
  /// kind of body defers to a field already written.
  ///
  /// ```swift
  /// var form = MultipartForm()
  /// form.append(name: "caption", value: "On the trail")
  /// form.append(contentType: "image/jpeg", data: photo, filename: "trail.jpg", name: "photo")
  ///
  /// try await client.executeExpectingNoContent(
  ///   Request(body: .multipart(form), method: .post, path: "/photos")
  /// )
  /// ```
  case multipart(MultipartForm)

  /// No payload.
  case none
}
