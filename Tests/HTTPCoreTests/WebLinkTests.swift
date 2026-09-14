import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

@Suite("WebLink.links(in:)", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct WebLinkTests {
  /// Header fields carrying one `Link` field per value, in order.
  private func fields(_ values: String...) throws -> HTTPFields {
    let name = try #require(HTTPField.Name("Link"))
    var fields: HTTPFields = [:]
    for value in values {
      fields.append(HTTPField(name: name, value: value))
    }
    return fields
  }

  @Test("The RFC 8288 previous-chapter example reads its target, relation, and title")
  func rfcPreviousChapterExample() throws {
    let links = try WebLink.links(
      in: fields(
        #"<http://example.com/TheBook/chapter2>; rel="previous"; "#
          + #"title="previous chapter""#
      )
    )
    #expect(
      links == [
        WebLink(
          parameters: ["rel": "previous", "title": "previous chapter"],
          relations: ["previous"],
          target: "http://example.com/TheBook/chapter2"
        )
      ]
    )
  }

  @Test("The RFC 8288 extension relation example keeps the relation URI")
  func rfcExtensionRelationExample() throws {
    let links = try WebLink.links(in: fields(#"</>; rel="http://example.net/foo""#))
    #expect(
      links == [
        WebLink(
          parameters: ["rel": "http://example.net/foo"],
          relations: ["http://example.net/foo"],
          target: "/"
        )
      ]
    )
  }

  @Test("The RFC 8288 anchor example keeps the anchor parameter")
  func rfcAnchorExample() throws {
    let links = try WebLink.links(in: fields(##"</terms>; rel="copyright"; anchor="#foo""##))
    #expect(
      links == [
        WebLink(
          parameters: ["anchor": "#foo", "rel": "copyright"],
          relations: ["copyright"],
          target: "/terms"
        )
      ]
    )
  }

  @Test("The RFC 8288 two-link example reads both links and keeps title* undecoded")
  func rfcTwoLinkExample() throws {
    let links = try WebLink.links(
      in: fields(
        #"</TheBook/chapter2>; rel="previous"; title*=UTF-8'de'letztes%20Kapitel, "#
          + #"</TheBook/chapter4>; rel="next"; title*=UTF-8'de'n%c3%a4chstes%20Kapitel"#
      )
    )
    #expect(
      links == [
        WebLink(
          parameters: ["rel": "previous", "title*": "UTF-8'de'letztes%20Kapitel"],
          relations: ["previous"],
          target: "/TheBook/chapter2"
        ),
        WebLink(
          parameters: ["rel": "next", "title*": "UTF-8'de'n%c3%a4chstes%20Kapitel"],
          relations: ["next"],
          target: "/TheBook/chapter4"
        ),
      ]
    )
  }

  @Test("The RFC 8288 multiple-relation example gives both relation types")
  func rfcMultipleRelationExample() throws {
    let links = try WebLink.links(
      in: fields(#"<http://example.org/>; rel="start http://example.net/relation/other""#)
    )
    #expect(
      links == [
        WebLink(
          parameters: ["rel": "start http://example.net/relation/other"],
          relations: ["start", "http://example.net/relation/other"],
          target: "http://example.org/"
        )
      ]
    )
  }

  @Test("Two Link fields are read in the order they appear")
  func twoFieldsReadInOrder() throws {
    let links = try WebLink.links(in: fields("</a>; rel=next", "</b>; rel=last"))
    #expect(
      links == [
        WebLink(parameters: ["rel": "next"], relations: ["next"], target: "/a"),
        WebLink(parameters: ["rel": "last"], relations: ["last"], target: "/b"),
      ]
    )
  }

  @Test("A rel value listing two types gives two relations")
  func relationListSplitsOnWhitespace() throws {
    let links = try WebLink.links(in: fields(#"</items?page=9>; rel="next last""#))
    #expect(links.map(\.relations) == [["next", "last"]])
  }

  @Test("A parameter name in capitals is stored lowercased and its relation is lowercased")
  func uppercaseNameAndRelationAreLowercased() throws {
    let links = try WebLink.links(in: fields("</a>; REL=Next"))
    #expect(links == [WebLink(parameters: ["rel": "Next"], relations: ["next"], target: "/a")])
  }

  @Test("A quoted title may contain a comma and a semicolon")
  func quotedValueContainsSeparators() throws {
    let links = try WebLink.links(in: fields(#"</a>; title="one, two; three"; rel=next, </b>"#))
    #expect(
      links == [
        WebLink(
          parameters: ["rel": "next", "title": "one, two; three"],
          relations: ["next"],
          target: "/a"
        ),
        WebLink(parameters: [:], relations: [], target: "/b"),
      ]
    )
  }

  @Test("A backslash in a quoted value escapes the quote after it")
  func escapedQuoteIsUnescaped() throws {
    let links = try WebLink.links(in: fields(#"</a>; title="say \"hi\" \\ there""#))
    #expect(links.map(\.parameters) == [["title": #"say "hi" \ there"#]])
  }

  @Test("A link with no parameters has an empty parameter set and no relations")
  func linkWithoutParameters() throws {
    let links = try WebLink.links(in: fields("<https://api.example.com/items?page=2>"))
    #expect(
      links == [
        WebLink(parameters: [:], relations: [], target: "https://api.example.com/items?page=2")
      ]
    )
  }

  @Test("A link with parameters but no rel has no relations")
  func linkWithoutRelation() throws {
    let links = try WebLink.links(in: fields(#"</a>; title="first""#))
    #expect(links == [WebLink(parameters: ["title": "first"], relations: [], target: "/a")])
  }

  @Test("A parameter written without a value is stored as the empty string")
  func valuelessParameterIsEmpty() throws {
    let links = try WebLink.links(in: fields("</a>; crossorigin; rel=next"))
    #expect(links.map(\.parameters) == [["crossorigin": "", "rel": "next"]])
  }

  @Test("A malformed link between two good ones is skipped and both good links are read")
  func malformedLinkIsSkipped() throws {
    let links = try WebLink.links(
      in: fields(#"</a>; rel=prev, /b; rel="x, y", </c>; rel=next"#)
    )
    #expect(
      links == [
        WebLink(parameters: ["rel": "prev"], relations: ["prev"], target: "/a"),
        WebLink(parameters: ["rel": "next"], relations: ["next"], target: "/c"),
      ]
    )
  }

  @Test("A target that never closes before the next link's target does not swallow that link")
  func unclosedTargetDoesNotSwallowNextLink() throws {
    let links = try WebLink.links(in: fields("<a, <https://x>; rel=next"))
    #expect(
      links == [WebLink(parameters: ["rel": "next"], relations: ["next"], target: "https://x")]
    )
  }

  @Test("An extension relation type in mixed case is lowercased and its parameter kept as written")
  func extensionRelationIsLowercased() throws {
    let links = try WebLink.links(in: fields(#"</a>; rel="https://Example.com/Rels/Next""#))
    #expect(
      links == [
        WebLink(
          parameters: ["rel": "https://Example.com/Rels/Next"],
          relations: ["https://example.com/rels/next"],
          target: "/a"
        )
      ]
    )
  }

  @Test("An unterminated quote ends its field and a later Link field is still read")
  func unterminatedQuoteEndsOnlyItsField() throws {
    let links = try WebLink.links(
      in: fields(#"</a>; rel=next, </b>; title="open, </c>; rel=last"#, "</d>; rel=prev")
    )
    #expect(
      links == [
        WebLink(parameters: ["rel": "next"], relations: ["next"], target: "/a"),
        WebLink(parameters: ["rel": "prev"], relations: ["prev"], target: "/d"),
      ]
    )
  }

  @Test("A repeated parameter keeps its first occurrence, whatever the name's case")
  func duplicateParameterKeepsFirst() throws {
    let links = try WebLink.links(in: fields("</a>; rel=next; REL=prev; Title=one; title=two"))
    #expect(
      links == [
        WebLink(parameters: ["rel": "next", "title": "one"], relations: ["next"], target: "/a")
      ]
    )
  }

  @Test("Header fields without a Link field give no links")
  func noLinkFieldGivesNoLinks() {
    #expect(WebLink.links(in: [:]).isEmpty)
    #expect(WebLink.links(in: [.contentType: "</a>; rel=next"]).isEmpty)
  }
}
