import HTTPCore
import HTTPTesting
import Testing

@Suite("Authentication", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct AuthenticationTests {
  @Test("the defaults carry no refresher, enable replay, and leave proactive refresh off")
  func defaults() {
    let authentication = Authentication(provider: RecordingTokenProvider(token: "t1"))
    #expect(authentication.provider.currentToken() == "t1")
    #expect(authentication.refresher == nil)
    #expect(authentication.refreshThreshold == nil)
    #expect(authentication.replayOn401)
  }

  @Test("the default scheme is bearer")
  func defaultScheme() {
    let authentication = Authentication(provider: RecordingTokenProvider(token: "t1"))
    #expect(authentication.scheme == .bearer)
  }

  @Test("a Basic credential is the base64 of the user name, a colon, and the password")
  func basicCredential() {
    #expect(
      Authentication.basicCredential(password: "open sesame", username: "Aladdin")
        == "QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
  }

  @Test("a colon in the password is encoded like any other character")
  func basicCredentialWithAColonInThePassword() {
    #expect(
      Authentication.basicCredential(password: "pa:ss", username: "user") == "dXNlcjpwYTpzcw==")
  }

  @Test("a colon in the user name is encoded as given, unchecked")
  func basicCredentialWithAColonInTheUserName() {
    #expect(
      Authentication.basicCredential(password: "pass", username: "us:er") == "dXM6ZXI6cGFzcw==")
  }

  @Test("an empty user name or an empty password is encoded as given")
  func basicCredentialWithAnEmptyHalf() {
    #expect(Authentication.basicCredential(password: "", username: "") == "Og==")
    #expect(Authentication.basicCredential(password: "", username: "user") == "dXNlcjo=")
  }

  @Test("a password outside ASCII is encoded as UTF-8")
  func basicCredentialWithANonASCIIPassword() {
    #expect(
      Authentication.basicCredential(password: "123£", username: "test") == "dGVzdDoxMjPCow==")
  }

  @Test("the rules can be narrowed on a copy without touching the original")
  func rulesNarrowOnACopy() {
    let tokens = RecordingTokenProvider(token: "t1")
    let original = Authentication(
      provider: tokens, refresher: tokens, refreshThreshold: .seconds(30))
    var narrowed = original
    narrowed.refreshThreshold = .seconds(5)
    narrowed.replayOn401 = false

    #expect(narrowed.refreshThreshold == .seconds(5))
    #expect(!narrowed.replayOn401)
    #expect(narrowed.refresher != nil)
    #expect(original.refreshThreshold == .seconds(30))
    #expect(original.replayOn401)
  }
}
