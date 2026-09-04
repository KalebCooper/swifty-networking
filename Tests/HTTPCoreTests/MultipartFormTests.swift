import HTTPCore
import HTTPTesting
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct MultipartFormTests {
  @Test("A text field is written as a form-data part carrying no media type of its own")
  func textFieldIsWrittenWithoutAMediaType() {
    var form = MultipartForm(boundary: "abc")
    form.append(name: "caption", value: "On the trail")

    let expected = [
      "--abc\r\n",
      "Content-Disposition: form-data; name=\"caption\"\r\n",
      "\r\n",
      "On the trail\r\n",
      "--abc--\r\n",
    ].joined()
    #expect(form.encoded == Data(expected.utf8))
    #expect(form.contentType == "multipart/form-data; boundary=abc")
  }

  @Test("A file is written with its file name and its own media type")
  func fileIsWrittenWithItsFilenameAndMediaType() {
    var form = MultipartForm(boundary: "abc")
    form.append(
      contentType: "text/plain", data: Data("hello".utf8), filename: "note.txt", name: "file")

    let expected = [
      "--abc\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"note.txt\"\r\n",
      "Content-Type: text/plain\r\n",
      "\r\n",
      "hello\r\n",
      "--abc--\r\n",
    ].joined()
    #expect(form.encoded == Data(expected.utf8))
  }

  @Test("Parts are written in the order they were appended")
  func partsKeepTheOrderTheyWereAppended() {
    var form = MultipartForm(boundary: "abc")
    form.append(name: "first", value: "1")
    form.append(contentType: "text/plain", data: Data("2".utf8), filename: "b.txt", name: "second")
    form.append(name: "third", value: "3")

    let expected = [
      "--abc\r\n",
      "Content-Disposition: form-data; name=\"first\"\r\n",
      "\r\n",
      "1\r\n",
      "--abc\r\n",
      "Content-Disposition: form-data; name=\"second\"; filename=\"b.txt\"\r\n",
      "Content-Type: text/plain\r\n",
      "\r\n",
      "2\r\n",
      "--abc\r\n",
      "Content-Disposition: form-data; name=\"third\"\r\n",
      "\r\n",
      "3\r\n",
      "--abc--\r\n",
    ].joined()
    #expect(form.encoded == Data(expected.utf8))
  }

  @Test("A form with no parts is the closing delimiter and nothing else")
  func emptyFormIsTheClosingDelimiterAlone() {
    #expect(MultipartForm(boundary: "abc").encoded == Data("--abc--\r\n".utf8))
  }

  @Test("A quotation mark and a line break in a name and a file name are percent-encoded")
  func quotesAndLineBreaksInNamesArePercentEncoded() {
    var form = MultipartForm(boundary: "abc")
    form.append(
      contentType: "text/plain",
      data: Data(),
      filename: "re\r\nport\".txt",
      name: "the \"field\"")

    let expected = [
      "--abc\r\n",
      "Content-Disposition: form-data; name=\"the %22field%22\";",
      " filename=\"re%0D%0Aport%22.txt\"\r\n",
      "Content-Type: text/plain\r\n",
      "\r\n",
      "\r\n",
      "--abc--\r\n",
    ].joined()
    #expect(form.encoded == Data(expected.utf8))
  }

  @Test("A quotation mark in a text field's name is percent-encoded")
  func quotesInATextFieldsNameArePercentEncoded() {
    var form = MultipartForm(boundary: "abc")
    form.append(name: "the \"field\"", value: "x")

    let expected = [
      "--abc\r\n",
      "Content-Disposition: form-data; name=\"the %22field%22\"\r\n",
      "\r\n",
      "x\r\n",
      "--abc--\r\n",
    ].joined()
    #expect(form.encoded == Data(expected.utf8))
  }

  @Test(
    "A line break in a media type is percent-encoded, so a part cannot open a header of its own")
  func lineBreaksInAMediaTypeArePercentEncoded() {
    var form = MultipartForm(boundary: "abc")
    form.append(
      contentType: "text/plain\r\nX-Injected: yes",
      data: Data(),
      filename: "note.txt",
      name: "file")

    let expected = [
      "--abc\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"note.txt\"\r\n",
      "Content-Type: text/plain%0D%0AX-Injected: yes\r\n",
      "\r\n",
      "\r\n",
      "--abc--\r\n",
    ].joined()
    #expect(form.encoded == Data(expected.utf8))
  }

  @Test("A part carrying the boundary in its bytes is written unguarded")
  func aPartCarryingTheBoundaryIsWrittenUnguarded() {
    var form = MultipartForm(boundary: "abc")
    form.append(name: "quote", value: "--abc--")

    let expected = [
      "--abc\r\n",
      "Content-Disposition: form-data; name=\"quote\"\r\n",
      "\r\n",
      "--abc--\r\n",
      "--abc--\r\n",
    ].joined()
    #expect(form.encoded == Data(expected.utf8))
  }

  @Test("A name outside ASCII is written as its UTF-8 bytes")
  func nonASCIINameIsWrittenAsUTF8() {
    var form = MultipartForm(boundary: "abc")
    form.append(name: "caf\u{00E9}", value: "x")

    var expected = Data("--abc\r\nContent-Disposition: form-data; name=\"caf".utf8)
    expected.append(contentsOf: [0xC3, 0xA9])
    expected.append(contentsOf: "\"\r\n\r\nx\r\n--abc--\r\n".utf8)
    #expect(form.encoded == expected)
  }

  @Test("Bytes that are not text are written unchanged")
  func binaryDataIsWrittenUnchanged() {
    var form = MultipartForm(boundary: "abc")
    let payload = Data([0x00, 0xFF, 0x0D, 0x0A, 0x2D, 0x2D])
    form.append(
      contentType: "application/octet-stream", data: payload, filename: "raw.bin", name: "file")

    var expected = Data(
      [
        "--abc\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"raw.bin\"\r\n",
        "Content-Type: application/octet-stream\r\n",
        "\r\n",
      ].joined().utf8)
    expected.append(payload)
    expected.append(contentsOf: "\r\n--abc--\r\n".utf8)
    #expect(form.encoded == expected)
  }

  @Test("A generated boundary is thirty-two letters and digits, and no two forms share one")
  func generatedBoundariesAreAlphanumericAndDistinct() {
    let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    let boundaries = (0..<32).map { _ in MultipartForm().boundary }

    for boundary in boundaries {
      #expect(boundary.count == 32)
      #expect(boundary.allSatisfy(alphabet.contains))
    }
    #expect(Set(boundaries).count == boundaries.count)
  }
}
