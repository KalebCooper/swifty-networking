#if canImport(Darwin)
import Foundation
import Security
import Synchronization
import WebSocketCore

/// A local test CA and its localhost server identity; no trust settings are installed and nothing
/// is written to a keychain.
///
/// Both are loaded once per process: reading the files and importing the PKCS #12 archive are
/// synchronous calls into the Security framework, which would otherwise hold a cooperative thread
/// on every test. The results are kept rather than trapped so a bad fixture fails the test that
/// reads it.
enum AppleTLSFixture {
  /// The test CA that signed the server identity.
  static let certificate = Result { () throws -> SecCertificate in
    let url = try resource("TestCA", extension: "der")
    guard let certificate = SecCertificateCreateWithData(nil, try Data(contentsOf: url) as CFData)
    else { throw WebSocketError(kind: .transport) }
    return certificate
  }

  // `SecIdentity` is not `Sendable`, so the identity stays inside the lock and only the server
  // built from it leaves.
  private static let identity = Mutex(Result { try importIdentity() })

  /// A TLS server that presents the fixture identity.
  static func server(
    handler: @escaping @Sendable (WebSocketServer.Peer, String) async throws -> Void
  ) throws -> WebSocketServer {
    try identity.withLock { identity in
      try WebSocketServer(identity: identity.get(), handler: handler)
    }
  }

  private static func importIdentity() throws -> SecIdentity {
    let url = try resource("ServerIdentity", extension: "p12")
    // On macOS an import otherwise lands in the login keychain with an access list naming the
    // importing binary, and a later test process signing with that key waits on an access prompt
    // that a headless host never answers.
    let options =
      [kSecImportExportPassphrase as String: "fixture", kSecImportToMemoryOnly as String: true]
      as CFDictionary
    var items: CFArray?
    guard SecPKCS12Import(try Data(contentsOf: url) as CFData, options, &items) == errSecSuccess,
      let entries = items as? [[String: Any]],
      let identity = entries.first?[kSecImportItemIdentity as String]
    else { throw WebSocketError(kind: .transport) }
    guard CFGetTypeID(identity as CFTypeRef) == SecIdentityGetTypeID() else {
      throw WebSocketError(kind: .transport)
    }
    return unsafeDowncast(identity as AnyObject, to: SecIdentity.self)
  }

  private static func resource(_ name: String, extension suffix: String) throws -> URL {
    guard
      let url = Bundle.module.url(
        forResource: name, withExtension: suffix, subdirectory: "Fixtures")
    else { throw WebSocketError(kind: .transport) }
    return url
  }
}
#endif
