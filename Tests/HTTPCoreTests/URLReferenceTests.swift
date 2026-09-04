import HTTPCore
import HTTPTesting
import Testing

/// The base every example in RFC 3986 is resolved against, as the RFC writes it.
private let base = "http://a/b/c/d;p?q"

@Suite("URLReference.resolve(_:against:)", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct URLReferenceTests {
  @Test(
    "The normal examples in RFC 3986 5.4.1 resolve to the strings the RFC lists",
    arguments: [
      ("g:h", "g:h"),
      ("g", "http://a/b/c/g"),
      ("./g", "http://a/b/c/g"),
      ("g/", "http://a/b/c/g/"),
      ("/g", "http://a/g"),
      ("//g", "http://g"),
      ("?y", "http://a/b/c/d;p?y"),
      ("g?y", "http://a/b/c/g?y"),
      (";x", "http://a/b/c/;x"),
      ("g;x", "http://a/b/c/g;x"),
      ("", "http://a/b/c/d;p?q"),
      (".", "http://a/b/c/"),
      ("./", "http://a/b/c/"),
      ("..", "http://a/b/"),
      ("../", "http://a/b/"),
      ("../g", "http://a/b/g"),
      ("../..", "http://a/"),
      ("../../", "http://a/"),
      ("../../g", "http://a/g"),
    ]
  )
  func normalExamplesResolveAsTheRFCLists(reference: String, expected: String) {
    #expect(URLReference.resolve(reference, against: base) == expected)
  }

  @Test(
    "The abnormal examples in RFC 3986 5.4.2 resolve to the strings the RFC lists",
    arguments: [
      ("../../../g", "http://a/g"),
      ("../../../../g", "http://a/g"),
      ("/./g", "http://a/g"),
      ("/../g", "http://a/g"),
      ("g.", "http://a/b/c/g."),
      (".g", "http://a/b/c/.g"),
      ("g..", "http://a/b/c/g.."),
      ("..g", "http://a/b/c/..g"),
      ("./../g", "http://a/b/g"),
      ("./g/.", "http://a/b/c/g/"),
      ("g/./h", "http://a/b/c/g/h"),
      ("g/../h", "http://a/b/c/h"),
      ("g;x=1/./y", "http://a/b/c/g;x=1/y"),
      ("g;x=1/../y", "http://a/b/c/y"),
      ("g?y/./x", "http://a/b/c/g?y/./x"),
      ("g?y/../x", "http://a/b/c/g?y/../x"),
      // The RFC gives two answers for a reference carrying the base's own scheme. This is the one
      // it marks for strict parsers, which is what a resolver that never guesses has to be.
      ("http:g", "http:g"),
    ]
  )
  func abnormalExamplesResolveAsTheRFCLists(reference: String, expected: String) {
    #expect(URLReference.resolve(reference, against: base) == expected)
  }

  /// The RFC's own answer for each of these carries a fragment, and an HTTP request target has
  /// none, so each expectation below is the RFC's string with its `#` and everything after it
  /// removed. Nothing else about the example changes.
  @Test(
    "A fragment the reference writes is dropped, so the RFC's example resolves without it",
    arguments: [
      ("#s", "http://a/b/c/d;p?q"),
      ("g#s", "http://a/b/c/g"),
      ("g?y#s", "http://a/b/c/g?y"),
      ("g;x?y#s", "http://a/b/c/g;x?y"),
      ("g#s/./x", "http://a/b/c/g"),
      ("g#s/../x", "http://a/b/c/g"),
    ]
  )
  func aFragmentOnTheReferenceIsDropped(reference: String, expected: String) {
    #expect(URLReference.resolve(reference, against: base) == expected)
  }

  @Test("A fragment the base carries takes no part in the resolution")
  func aFragmentOnTheBaseIsIgnored() {
    #expect(URLReference.resolve("g", against: "http://a/b/c/d;p?q#s") == "http://a/b/c/g")
    #expect(URLReference.resolve("", against: "http://a/b/c/d;p?q#s") == "http://a/b/c/d;p?q")
  }

  @Test("A base that names no path merges the reference onto its root")
  func aBaseWithoutAPathMergesOntoItsRoot() {
    #expect(URLReference.resolve("g", against: "http://a") == "http://a/g")
    #expect(URLReference.resolve("g", against: "http://a?q") == "http://a/g")
  }

  /// The RFC lists no network-path reference carrying dot segments. This one is the two rules the
  /// RFC does state, read together: the reference brings its own authority, and the path it brings
  /// has its dot segments removed, so `/x/../y` becomes `/y` under the authority `g` rather than
  /// under the base's.
  @Test("A network-path reference has its own dot segments removed under its own authority")
  func aNetworkPathReferenceRemovesItsOwnDotSegments() {
    #expect(URLReference.resolve("//g/x/../y", against: base) == "http://g/y")
  }

  @Test("A question mark inside a fragment is no query, and a colon inside a path is no scheme")
  func delimitersAreReadInGrammarOrder() {
    #expect(URLReference.resolve("g#s?x", against: base) == "http://a/b/c/g")
    #expect(URLReference.resolve("a/b:c", against: base) == "http://a/b/c/a/b:c")
  }

  @Test("A reference that writes an empty query keeps its question mark")
  func anEmptyQueryIsKept() {
    #expect(URLReference.resolve("g?", against: base) == "http://a/b/c/g?")
    #expect(URLReference.resolve("?", against: base) == "http://a/b/c/d;p?")
  }

  @Test(
    "A base that names no scheme, or no host, resolves nothing",
    arguments: [
      "/a/b",
      "a/b/c",
      "//a/b",
      "http://",
      "mailto:me@example.com",
      "http:g",
      "1http://a/b",
    ]
  )
  func aBaseWithoutASchemeOrHostResolvesNothing(base: String) {
    #expect(URLReference.resolve("g", against: base) == nil)
  }
}

/// The origin of a URL's authority, as RFC 6454 compares them: case folded, the port defaulted by
/// scheme, userinfo dropped, an IPv6 literal kept whole.
@Suite("URLReference.Origin", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct URLReferenceOriginTests {
  @Test(
    "an authority reads as its host and port, with the scheme's default where none is written",
    arguments: [
      ("[::1]:8080", "[::1]", 8080),
      ("[::1]", "[::1]", 443),
      ("host:", "host", 443),
      ("user:pw@host", "host", 443),
      ("HOST", "host", 443),
      ("host:8443", "host", 8443),
    ]
  )
  func hostAndPort(authority: String, host: String, port: Int) {
    let origin = URLReference.Origin(authority: authority, scheme: "https")

    #expect(origin?.host == host)
    #expect(origin?.port == port)
    #expect(origin?.scheme == "https")
  }

  @Test("http defaults to 80, a scheme with no default to no port, and a non-number to no port")
  func portDefaults() {
    #expect(URLReference.Origin(authority: "a", scheme: "http")?.port == 80)
    #expect(URLReference.Origin(authority: "a", scheme: "ftp")?.port == nil)
    #expect(URLReference.Origin(authority: "a:abc", scheme: "https")?.port == nil)
  }

  @Test(
    "an authority naming no host, or a missing scheme or authority, is no origin",
    arguments: [(":80", "https"), ("", "https"), ("user@", "https"), ("a", ""), ("a", nil)])
  func noOrigin(authority: String, scheme: String?) {
    #expect(URLReference.Origin(authority: authority, scheme: scheme) == nil)
    #expect(URLReference.Origin(authority: nil, scheme: "https") == nil)
  }

  @Test("two spellings of one origin are equal, and a port or scheme change makes another")
  func equality() {
    let origin = URLReference.Origin(authority: "API.example.com:443", scheme: "HTTPS")

    #expect(origin == URLReference.Origin(authority: "api.example.com", scheme: "https"))
    #expect(origin != URLReference.Origin(authority: "api.example.com:8443", scheme: "https"))
    #expect(origin != URLReference.Origin(authority: "api.example.com", scheme: "http"))
  }
}
