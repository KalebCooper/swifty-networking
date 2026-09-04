// The fixture serves suites that exist only behind the `HTTPPortable` trait, so it compiles only
// where those do.
#if HTTPPortable

// `URL` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension URL {
  /// A URL from a literal that is known to parse.
  ///
  /// A literal that does not parse is a mistake in the test that wrote it, so it stops the run
  /// instead of becoming an optional every test has to unwrap.
  static func fixture(_ literal: StaticString) -> URL {
    guard let url = URL(string: "\(literal)") else {
      preconditionFailure("\(literal) is not a URL")
    }
    return url
  }
}

#endif
