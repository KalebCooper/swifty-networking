// `URLComponents` comes with the same loading system as `URLSession`, so this helper compiles only
// on the platforms the rest of the target does.
#if canImport(Darwin)

import Foundation

extension URL {
  /// The URL reduced to what identifies the endpoint, with every component a credential can travel
  /// in removed.
  ///
  /// Query, fragment, and any user or password in the authority are dropped. A signed URL carries
  /// its signature in the query, so a description that echoes it is not safe to log. A URL that
  /// cannot be parsed into components answers `nil`.
  var redacted: String? {
    guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.fragment = nil
    components.password = nil
    components.query = nil
    components.user = nil
    return components.string
  }
}

#endif
