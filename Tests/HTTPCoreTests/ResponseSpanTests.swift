import HTTPCore
import HTTPTesting
import HTTPTypes
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite("Response.contentTypeSniff()", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct ResponseContentTypeSniffTests {
  @Test(
    "leading bytes decide the answer",
    arguments: [
      ("", ContentTypeSniff.empty),
      (" ", .empty),
      ("\n", .empty),
      ("\r\n", .empty),
      ("\t", .empty),
      (" \t\r\n ", .empty),
      ("{}", .json),
      ("{\"code\":409}", .json),
      ("[]", .json),
      ("[1,2,3]", .json),
      ("  {\"code\":409}", .json),
      ("\n\n[1]", .json),
      ("\r\n\t {}", .json),
      ("<html><body>502 Bad Gateway</body></html>", .html),
      ("<!DOCTYPE html>", .html),
      ("  <html>", .html),
      ("<HTML>", .html),
      ("<!doctype html>", .html),
      ("\n<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\">", .html),
      // The signature is a prefix and nothing after it is examined.
      ("<htmlish>", .html),
      ("<head><title>Gateway</title></head>", .unknown),
      ("<hr>", .unknown),
      ("<!DOCTYPE svg>", .unknown),
      ("<?xml version=\"1.0\"?>", .xml),
      ("  <?xml version=\"1.0\"?><html>", .xml),
      ("<?XML version=\"1.0\"?>", .xml),
      ("<?php echo 1;", .unknown),
      ("%PDF-1.7", .pdf),
      ("%PDF", .unknown),
      // A binary signature is read at the first byte, so whitespace in front of one disqualifies it.
      (" %PDF-1.7", .unknown),
      ("plain text", .unknown),
      ("name=value&other=thing", .unknown),
      // Valid JSON that does not begin with a structural byte.
      ("\"a string\"", .unknown),
      ("123", .unknown),
      ("true", .unknown),
      ("null", .unknown),
    ]
  )
  func sniffsLeadingBytes(body: String, expected: ContentTypeSniff) {
    #expect(Response(body: Data(body.utf8), status: .ok).contentTypeSniff() == expected)
  }

  @Test(
    "a binary signature is read at the very first byte",
    arguments: [
      ([0x1F, 0x8B, 0x08] as [UInt8], ContentTypeSniff.gzip),
      ([0x1F, 0x8C, 0x08], .unknown),
      ([0x20, 0x1F, 0x8B], .unknown),
      ([0xFF, 0xD8, 0xFF, 0xE0], .jpeg),
      ([0xFF, 0xD8, 0xFE], .unknown),
      ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .png),
      // Four of the eight bytes spell `PNG` and are not the signature.
      ([0x89, 0x50, 0x4E, 0x47], .unknown),
      ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0B], .unknown),
      ([0x00, 0x01, 0xFF, 0x7B], .unknown),
    ]
  )
  func sniffsBinarySignatures(body: [UInt8], expected: ContentTypeSniff) {
    #expect(Response(body: Data(body), status: .ok).contentTypeSniff() == expected)
  }

  @Test("a response with no body at all is empty")
  func sniffsMissingBody() {
    #expect(Response(status: .noContent).contentTypeSniff() == .empty)
  }

  @Test("the Content-Type field is not consulted")
  func ignoresContentTypeField() {
    let mislabelled = Response(
      body: Data("<html>gateway timeout</html>".utf8),
      headers: [.contentType: "application/json"],
      status: .badGateway
    )
    #expect(mislabelled.contentTypeSniff() == .html)

    let unlabelled = Response(body: Data("{\"ok\":true}".utf8), status: .ok)
    #expect(unlabelled.contentTypeSniff() == .json)
  }
}
