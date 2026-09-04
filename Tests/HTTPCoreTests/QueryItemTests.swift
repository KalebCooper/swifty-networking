import HTTPCore
import HTTPTesting
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct QueryItemTests {
  @Test(
    "Unreserved characters pass through untouched",
    arguments: ["", "abc", "ABCxyz", "0123456789", "-._~", "a-b_c.d~e"]
  )
  func unreservedPassesThrough(raw: String) {
    #expect(QueryItem(name: raw, value: raw).percentEncoded == "\(raw)=\(raw)")
  }

  @Test(
    "Reserved and delimiter characters are percent-encoded",
    arguments: [
      ("&", "%26"), ("=", "%3D"), ("?", "%3F"), ("#", "%23"), ("/", "%2F"), ("+", "%2B"),
      ("%", "%25"), (" ", "%20"), (":", "%3A"), ("@", "%40"), ("!", "%21"), ("$", "%24"),
      ("'", "%27"), ("(", "%28"), (")", "%29"), ("*", "%2A"), (",", "%2C"), (";", "%3B"),
      ("[", "%5B"), ("]", "%5D"), ("\"", "%22"), ("<", "%3C"), (">", "%3E"), ("\\", "%5C"),
      ("^", "%5E"), ("`", "%60"), ("{", "%7B"), ("|", "%7C"), ("}", "%7D"),
    ]
  )
  func reservedIsEncoded(raw: String, encoded: String) {
    #expect(QueryItem(name: "k", value: raw).percentEncoded == "k=\(encoded)")
  }

  @Test(
    "Control bytes are percent-encoded",
    arguments: [("\u{00}", "%00"), ("\n", "%0A"), ("\r", "%0D"), ("\t", "%09"), ("\u{7F}", "%7F")]
  )
  func controlBytesAreEncoded(raw: String, encoded: String) {
    #expect(QueryItem(name: "k", value: raw).percentEncoded == "k=\(encoded)")
  }

  @Test(
    "Non-ASCII text encodes as its UTF-8 bytes with uppercase hex",
    arguments: [
      ("é", "%C3%A9"), ("ÿ", "%C3%BF"), ("日本", "%E6%97%A5%E6%9C%AC"), ("😀", "%F0%9F%98%80"),
      ("e\u{0301}", "e%CC%81"),
    ]
  )
  func multibyteUTF8IsEncodedBytewise(raw: String, encoded: String) {
    #expect(QueryItem(name: "k", value: raw).percentEncoded == "k=\(encoded)")
  }

  @Test("The name is encoded by the same rule as the value")
  func nameIsEncoded() {
    #expect(QueryItem(name: "a b&c", value: "1").percentEncoded == "a%20b%26c=1")
  }

  @Test("A space is %20 and a literal plus is %2B, so neither can be mistaken for the other")
  func spaceAndPlusAreDistinct() {
    #expect(QueryItem(name: "q", value: "a+b c").percentEncoded == "q=a%2Bb%20c")
  }

  @Test("Input is raw: an existing percent escape is not preserved but re-encoded")
  func alreadyEncodedInputIsEncodedAgain() {
    #expect(QueryItem(name: "q", value: "%20").percentEncoded == "q=%2520")
  }

  @Test("A nil value renders the bare name; an empty value renders name=")
  func nilAndEmptyValuesDiffer() {
    #expect(QueryItem(name: "flag").percentEncoded == "flag")
    #expect(QueryItem(name: "flag", value: nil).percentEncoded == "flag")
    #expect(QueryItem(name: "flag", value: "").percentEncoded == "flag=")
  }

  @Test("A URLQueryItem converts with its name and value carried raw")
  func urlQueryItemConverts() {
    let item = QueryItem(URLQueryItem(name: "q", value: "tea & coffee"))
    #expect(item.name == "q")
    #expect(item.value == "tea & coffee")
    #expect(item.percentEncoded == "q=tea%20%26%20coffee")
  }

  @Test("A URLQueryItem with no value converts to a bare flag")
  func urlQueryItemWithoutValueIsAFlag() {
    let item = QueryItem(URLQueryItem(name: "verbose", value: nil))
    #expect(item.value == nil)
    #expect(item.percentEncoded == "verbose")
  }

  @Test("A collection joins items with & in order, keeping duplicates")
  func collectionJoinsInOrder() {
    let items = [
      QueryItem(name: "b", value: "2"),
      QueryItem(name: "a", value: "1"),
      QueryItem(name: "a", value: "3"),
      QueryItem(name: "flag"),
    ]
    #expect(items.percentEncoded == "b=2&a=1&a=3&flag")
  }

  @Test("An empty collection renders an empty string")
  func emptyCollectionIsEmpty() {
    #expect([QueryItem]().percentEncoded == "")
  }

  @Test("A single item renders without a separator")
  func singleItemHasNoSeparator() {
    #expect([QueryItem(name: "a", value: "1")].percentEncoded == "a=1")
  }

  @Test("Items are values: equal fields mean equal items")
  func itemsAreHashable() {
    #expect(QueryItem(name: "a", value: "1") == QueryItem(name: "a", value: "1"))
    #expect(QueryItem(name: "a", value: nil) != QueryItem(name: "a", value: ""))
    #expect(Set([QueryItem(name: "a"), QueryItem(name: "a")]).count == 1)
  }

  @Test(
    "A form body encodes a space as a plus and every other reserved character as %XX",
    arguments: [
      (" ", "+"), ("&", "%26"), ("=", "%3D"), ("+", "%2B"), ("%", "%25"), ("#", "%23"),
      ("?", "%3F"), ("/", "%2F"), (":", "%3A"), ("@", "%40"), ("\"", "%22"), (";", "%3B"),
      ("\n", "%0A"), ("*", "%2A"),
    ]
  )
  func formReservedIsEncoded(raw: String, encoded: String) {
    #expect(QueryItem(name: "k", value: raw).formEncoded == "k=\(encoded)")
  }

  @Test("A form body passes the unreserved characters through, the tilde among them")
  func formUnreservedPassesThrough() {
    #expect(QueryItem(name: "k", value: "aZ09-._~").formEncoded == "k=aZ09-._~")
  }

  @Test("A form space is a plus and a literal plus is %2B, so neither can be read as the other")
  func formSpaceAndPlusAreDistinct() {
    #expect(QueryItem(name: "q", value: "a+b c").formEncoded == "q=a%2Bb+c")
  }

  @Test(
    "Non-ASCII text in a form body encodes as its UTF-8 bytes with uppercase hex",
    arguments: [("é", "%C3%A9"), ("日本", "%E6%97%A5%E6%9C%AC"), ("😀", "%F0%9F%98%80")]
  )
  func formMultibyteUTF8IsEncodedBytewise(raw: String, encoded: String) {
    #expect(QueryItem(name: "k", value: raw).formEncoded == "k=\(encoded)")
  }

  @Test("A form name is encoded by the same rule as a form value")
  func formNameIsEncoded() {
    #expect(QueryItem(name: "a b&c", value: "1").formEncoded == "a+b%26c=1")
  }

  @Test("A nil value renders the bare name in a form body; an empty value renders name=")
  func formNilAndEmptyValuesDiffer() {
    #expect(QueryItem(name: "opt in").formEncoded == "opt+in")
    #expect(QueryItem(name: "flag", value: "").formEncoded == "flag=")
  }

  @Test("A form body joins items with & in order, keeping duplicates")
  func formCollectionJoinsInOrder() {
    let items = [
      QueryItem(name: "b", value: "2"),
      QueryItem(name: "a", value: "1"),
      QueryItem(name: "a", value: "3"),
      QueryItem(name: "flag"),
    ]
    #expect(items.formEncoded == "b=2&a=1&a=3&flag")
  }

  @Test("An empty collection renders an empty form body")
  func formEmptyCollectionIsEmpty() {
    #expect([QueryItem]().formEncoded == "")
  }
}
