// `Data` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTypes

/// A credential source paired with the rules a client applies around it.
///
/// The value applies only to requests whose ``RequestOptions/requiresAuth`` is `true`. Anonymous
/// requests are sent without a credential and never trigger a refresh. The ``provider`` is read at
/// send time on every attempt; the ``refresher``, when there is one, is what a `401` or an expiring
/// credential turns to for a new one.
///
/// Each rule depends on a collaborator being present. ``refreshThreshold`` has no effect when the
/// provider's ``TokenProvider/timeUntilExpiry`` is `nil` or when there is no refresher, and
/// ``replayOn401`` has no effect without a refresher. The defaults enable every behaviour the
/// configured collaborators support, and you narrow from there.
///
/// ```swift
/// let client = HTTPClient(
///   authentication: Authentication(
///     provider: tokenStore,
///     refresher: SessionRefresher(store: tokenStore),
///     refreshThreshold: .seconds(30)
///   ),
///   baseURL: URL(string: "https://api.example.com")!,
///   transport: transport
/// )
/// ```
///
/// ## Copies
///
/// A value made once and shared between clients is one credential: copies of it refresh on one
/// gate and coalesce with each other, and changing a rule on a copy keeps that sharing. A value
/// made again, even over the same provider, is another credential with a gate of its own. See
/// <doc:Authenticating>.
///
/// ```swift
/// var admin = client
/// admin.authentication = Authentication(provider: adminStore, refresher: adminRefresher)
/// ```
public struct Authentication: Sendable {
  /// How a client renders a credential into a request's header fields.
  ///
  /// The provider holds one string and knows nothing about how it is sent; the scheme is what
  /// turns that string into a header field. ``bearer``, the default, and ``basic`` both write the
  /// `Authorization` field with the prefix their name states, and ``field(_:)`` writes the token
  /// unprefixed into the field you name, which is what an API key is. See <doc:Authenticating>.
  ///
  /// ```swift
  /// Authentication(provider: keyStore, scheme: .field(HTTPField.Name("X-API-Key")!))
  /// ```
  ///
  /// Whichever scheme renders it, the credential goes out only on a request whose
  /// ``RequestOptions/requiresAuth`` is `true`, a `401` earns the same one refresh and one replay,
  /// and a hop to another origin is sent without the field the client attached.
  public enum Scheme: Hashable, Sendable {
    /// Writes `Basic <token>` into the `Authorization` field.
    ///
    /// The token is the credential RFC 7617 defines, the base64 of the user name, a colon, and the
    /// password. Encode it where you store it, with
    /// ``Authentication/basicCredential(password:username:)``: a provider hands the client a
    /// credential to send, and the client renders it without reading it.
    ///
    /// ```swift
    /// Authentication(provider: basicStore, scheme: .basic)
    /// ```
    case basic

    /// Writes `Bearer <token>` into the `Authorization` field.
    ///
    /// This is the default, and the scheme an OAuth 2.0 access token is sent under.
    ///
    /// ```swift
    /// Authentication(provider: tokenStore, refresher: refresher)
    /// ```
    case bearer

    /// Writes the token, with no prefix, into the header field the case names.
    ///
    /// ```swift
    /// Authentication(provider: keyStore, scheme: .field(HTTPField.Name("X-API-Key")!))
    /// ```
    ///
    /// Naming `.authorization` here is legal and means what it says: the token becomes the whole
    /// `Authorization` value, with no scheme word in front of it, which is how a server expecting a
    /// credential of its own design reads that field.
    case field(HTTPField.Name)

    /// The header field this scheme writes the credential into.
    var fieldName: HTTPField.Name {
      switch self {
      case .basic, .bearer: .authorization
      case .field(let name): name
      }
    }

    /// `token` as this scheme writes it into `fieldName`.
    ///
    /// - Parameter token: The credential as the provider holds it, with no scheme prefix.
    /// - Returns: The header field value to send.
    func value(for token: String) -> String {
      switch self {
      case .basic: "Basic \(token)"
      case .bearer: "Bearer \(token)"
      case .field: token
      }
    }
  }

  /// Builds the credential ``Scheme/basic`` sends, from a user name and a password.
  ///
  /// The credential RFC 7617 defines is the base64 of the user name, a colon, and the password. The
  /// pair is encoded as UTF-8, which is the encoding RFC 7617 recommends and the one a server names
  /// when its challenge carries the `charset` parameter; a server that reads the decoded bytes as
  /// something else needs its own encoding rather than this. A ``TokenProvider`` holds the one
  /// string that comes back, so build it where you hold the pair and return it from
  /// ``TokenProvider/currentToken()``; the client renders it into the `Authorization` field without
  /// reading it.
  ///
  /// ```swift
  /// func currentToken() -> String? {
  ///   Authentication.basicCredential(password: password, username: username)
  /// }
  /// ```
  ///
  /// The user name must not contain a colon, which RFC 7617 forbids: a server splits the decoded
  /// credential at the first colon it finds, so a colon in the user name moves where the password
  /// begins. The value is returned as given, unchecked. A colon in the password is legal and needs
  /// nothing done to it.
  ///
  /// - Parameters:
  ///   - password: The password, which may contain a colon.
  ///   - username: The user name, which must not contain a colon.
  /// - Returns: The credential to hold and send under ``Scheme/basic``.
  public static func basicCredential(password: String, username: String) -> String {
    Data("\(username):\(password)".utf8).base64EncodedString()
  }

  /// The source of the credential attached to each authenticated request.
  public let provider: any TokenProvider

  /// What obtains a fresh credential for ``provider``; `nil` treats a `401` like any other status
  /// failure and never refreshes ahead of a send.
  public let refresher: (any TokenRefresher)?

  /// The remaining credential lifetime at or below which the client refreshes before sending.
  ///
  /// A value of `nil` disables proactive refreshing. Size the threshold to the request's expected
  /// duration plus clock slack, so that a token valid at send time is still valid when the server
  /// checks it.
  public var refreshThreshold: Duration?

  /// A Boolean value that indicates whether a `401` response triggers one refresh and one replay.
  ///
  /// The replay happens at most once per logical request. A second `401` reaches you as
  /// ``TransportError/httpStatus(body:code:headers:)``. Set this to `false` for a server whose
  /// `401` means something other than an expired credential.
  public var replayOn401: Bool

  /// How the credential is rendered into a request's header fields.
  ///
  /// The default, ``Scheme/bearer``, writes `Authorization: Bearer <token>`. Every other rule this
  /// value carries reads the same whichever scheme renders it.
  public var scheme: Scheme

  /// The single refresh every request under this credential shares; made once per value and
  /// carried by every copy, so the gate is what makes two copies one credential. It exists even
  /// when ``refresher`` is `nil` and nothing will ever refresh through it, because its identity is
  /// what keeps this credential's coalesced flights apart from every other's.
  let gate = RefreshGate()

  /// Creates a credential source paired with its rules.
  ///
  /// - Parameters:
  ///   - provider: The source of the credential attached to each authenticated request.
  ///   - refresher: What obtains a fresh credential; defaults to `nil`, no refresh.
  ///   - refreshThreshold: The remaining lifetime at or below which to refresh before sending. The
  ///     default is `nil`, which disables proactive refreshing.
  ///   - replayOn401: Whether to refresh and replay once after a `401`. The default is `true`.
  ///   - scheme: How the credential is rendered into a request's header fields. The default is
  ///     ``Scheme/bearer``.
  public init(
    provider: any TokenProvider,
    refresher: (any TokenRefresher)? = nil,
    refreshThreshold: Duration? = nil,
    replayOn401: Bool = true,
    scheme: Scheme = .bearer
  ) {
    self.provider = provider
    self.refresher = refresher
    self.refreshThreshold = refreshThreshold
    self.replayOn401 = replayOn401
    self.scheme = scheme
  }

  /// What tells one credential from another: the gate's identity, which every copy of the value
  /// shares and no other value has.
  var identity: ObjectIdentifier { ObjectIdentifier(gate) }
}
