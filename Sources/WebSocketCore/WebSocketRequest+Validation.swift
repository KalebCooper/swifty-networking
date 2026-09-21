#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPCore
import HTTPTypes

extension WebSocketRequest {
  /// Rejects invalid handshake inputs before any credential collaborator is called.
  package func validate() throws(WebSocketError) {
    let address = url.absoluteString
    let parts = URLReference.parse(address)
    guard url.baseURL == nil, !address.contains("#"),
      let scheme = parts.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
      let authority = parts.authority, Self.validAuthority(authority),
      authentication == nil || scheme == "wss"
    else { throw WebSocketError(kind: .invalidRequest) }

    for field in headers {
      guard !Self.owns(field.name), HTTPField.isValidValue(field.value) else {
        throw WebSocketError(kind: .invalidRequest)
      }
    }
    if let authentication, Self.owns(authentication.scheme.fieldName) {
      throw WebSocketError(kind: .invalidRequest)
    }
    guard subprotocols.allSatisfy({ HTTPField.Name($0) != nil }),
      Set(subprotocols).count == subprotocols.count
    else { throw WebSocketError(kind: .invalidRequest) }
  }

  private static func owns(_ name: HTTPField.Name) -> Bool {
    let name = name.canonicalName
    return name.hasPrefix(":") || name.hasPrefix("sec-websocket-")
      || ["connection", "content-length", "host", "transfer-encoding", "upgrade"].contains(name)
  }

  private static func validAuthority(_ authority: String) -> Bool {
    guard !authority.isEmpty, !authority.contains("@") else { return false }
    let port: Substring?
    if authority.hasPrefix("[") {
      guard let end = authority.firstIndex(of: "]"),
        validIPv6(authority[authority.index(after: authority.startIndex)..<end])
      else { return false }
      let suffix = authority[authority.index(after: end)...]
      guard suffix.isEmpty || suffix.hasPrefix(":") else { return false }
      port = suffix.isEmpty ? nil : suffix.dropFirst()
    } else {
      let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
      guard pieces.count <= 2, let host = pieces.first, Self.validRegisteredName(host)
      else { return false }
      port = pieces.count == 2 ? pieces[1] : nil
    }
    guard let port else { return true }
    guard !port.isEmpty, port.utf8.allSatisfy({ (48...57).contains($0) }),
      let number = Int(port), (1...65_535).contains(number)
    else { return false }
    return true
  }

  private static func validIPv6(_ address: Substring) -> Bool {
    let halves = address.split(separator: "::", omittingEmptySubsequences: false)
    guard halves.count <= 2 else { return false }
    let groups = halves.flatMap { $0.split(separator: ":", omittingEmptySubsequences: false) }
      .filter { !$0.isEmpty }
    var count = 0
    for (index, group) in groups.enumerated() {
      if group.contains(".") {
        let octets = group.split(separator: ".", omittingEmptySubsequences: false)
        guard index == groups.count - 1, address.hasSuffix(group), octets.count == 4,
          octets.allSatisfy({
            !$0.isEmpty && ($0.count == 1 || $0.first != "0")
              && $0.utf8.allSatisfy { (48...57).contains($0) }
              && UInt8($0) != nil
          })
        else { return false }
        count += 2
      } else {
        guard group.count <= 4,
          group.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
          })
        else { return false }
        count += 1
      }
    }
    // A single compression marker stands for at least one group; lone/triple colons are invalid.
    guard !address.contains(":::"),
      !address.hasPrefix(":") || address.hasPrefix("::"),
      !address.hasSuffix(":") || address.hasSuffix("::")
    else { return false }
    return halves.count == 2 ? count < 8 : count == 8
  }

  private static func validRegisteredName(_ host: Substring) -> Bool {
    guard !host.isEmpty else { return false }
    var bytes = host.utf8.makeIterator()
    while let byte = bytes.next() {
      let decoded: UInt8
      if byte == 37 {
        guard let first = bytes.next(), let second = bytes.next(),
          let value = UInt8(String(decoding: [first, second], as: UTF8.self), radix: 16)
        else { return false }
        decoded = value
      } else {
        decoded = byte
      }
      guard
        (48...57).contains(decoded) || (65...90).contains(decoded)
          || (97...122).contains(decoded) || "-._~!$&'()*+,;=".utf8.contains(decoded)
      else { return false }
    }
    return true
  }
}
