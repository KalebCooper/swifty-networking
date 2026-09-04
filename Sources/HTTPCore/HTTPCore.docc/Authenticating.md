# Authenticating a Request

Pair a credential source with the rules around it, and let the client attach, refresh, and replay.

## Overview

``Authentication`` is one value holding a ``TokenProvider``, an optional ``TokenRefresher``, and the
two rules that govern them. It goes into a client as one argument, and every rule it carries is
opt-out rather than opt-in: the defaults enable every behaviour the collaborators you supplied can
support, and you narrow from there.

```swift
let store = TokenStore()

let client = HTTPClient(
  authentication: Authentication(
    provider: store,
    refresher: SessionRefresher(store: store),
    refreshThreshold: .seconds(30)
  ),
  baseURL: URL(string: "https://api.example.com/v1")!,
  transport: URLSessionTransport()
)
```

A request is authenticated only when its ``RequestOptions/requiresAuth`` is `true`, which is the
default, and only when the client has an ``HTTPClient/authentication``. Without one the request is
sent as written and a `401` is an ordinary status failure. With one, the credential is read from
``Authentication/provider`` at send time on every attempt and rendered into a header field under
``Authentication/scheme``, replacing whatever the defaults or the request set for that field. A
provider that returns `nil` leaves the field as you set it and the request goes out anyway. A
request whose `requiresAuth` is `false` never reads the provider and never triggers a refresh.

Each rule depends on a collaborator being present. ``Authentication/refreshThreshold`` has no effect
when the provider's ``TokenProvider/timeUntilExpiry`` is `nil` or when there is no refresher, and
``Authentication/replayOn401`` has no effect without a refresher.

## Choosing a Scheme

``Authentication/scheme`` is how the credential becomes a header field. The default,
``Authentication/Scheme/bearer``, sends `Authorization: Bearer <token>`;
``Authentication/Scheme/basic`` sends `Authorization: Basic <token>`; and
``Authentication/Scheme/field(_:)`` sends the token unprefixed in the field it names, which is what
an API key is.

```swift
Authentication(provider: keyStore, scheme: .field(HTTPField.Name("X-API-Key")!))
```

The provider holds one string whichever scheme sends it, so a `basic` credential is the base64 RFC
7617 defines, the user name, a colon, and the password, encoded where you store it rather than by
the client. ``Authentication/basicCredential(password:username:)`` builds that string from the pair.
Every other rule reads the same under every scheme: ``RequestOptions/requiresAuth``
decides whether a credential goes out, a `401` earns one refresh and one replay, and a hop to
another origin is sent without the field the client attached, whichever field that is.

## Logging In and Storing the Token

Where the credential comes from is yours, and a Bearer token usually comes from a login endpoint.
That request carries no credential of its own, so its ``RequestOptions/requiresAuth`` is `false`.
What comes back goes to the Keychain, and the provider reads it from there on every send. `Keychain`
below is a wrapper of your own over the Security framework, holding one string per name.

```swift
final class KeychainTokenStore: TokenProvider, Sendable {
  private let keychain: Keychain

  init(keychain: Keychain) { self.keychain = keychain }

  func currentToken() -> String? { keychain.string(for: "accessToken") }
  func install(_ token: String) { keychain.set(token, for: "accessToken") }
}

struct Session: Decodable {
  let accessToken: String
}

let store = KeychainTokenStore(keychain: Keychain())

let session: Session = try await client.execute(
  Request(
    body: .form([
      QueryItem(name: "password", value: password),
      QueryItem(name: "username", value: username),
    ]),
    method: .post,
    options: RequestOptions(requiresAuth: false),
    path: "/login"
  )
)
store.install(session.accessToken)
```

A ``TokenRefresher`` over the same store is what a `401` turns to. It logs in again and installs
what it gets, and the client replays the request with whatever the store then holds.

```swift
struct SessionRefresher: TokenRefresher {
  let store: KeychainTokenStore

  func refresh() async throws(TransportError) {
    store.install(try await logIn().accessToken)
  }
}

let client = HTTPClient(
  authentication: Authentication(provider: store, refresher: SessionRefresher(store: store)),
  baseURL: URL(string: "https://api.example.com")!,
  transport: URLSessionTransport()
)
```

## Encoding a Basic Credential

A self-hosted service that takes a user name and a password rather than a token is
``Authentication/Scheme/basic``, and the credential it wants is the base64 RFC 7617 defines.
``Authentication/basicCredential(password:username:)`` builds that string, so a provider over a
Keychain-held pair is the whole of it.

```swift
final class KeychainBasicStore: TokenProvider, Sendable {
  private let keychain: Keychain

  init(keychain: Keychain) { self.keychain = keychain }

  func currentToken() -> String? {
    guard let password = keychain.string(for: "password"),
      let username = keychain.string(for: "username")
    else { return nil }
    return Authentication.basicCredential(password: password, username: username)
  }
}

let client = HTTPClient(
  authentication: Authentication(
    provider: KeychainBasicStore(keychain: Keychain()), scheme: .basic),
  baseURL: URL(string: "https://files.example.com")!,
  transport: URLSessionTransport()
)
```

The user name must not contain a colon, which RFC 7617 forbids: the server splits the decoded
credential at the first one it finds. A colon in the password is legal. There is no refresher here,
since a `401` under a password means the password is wrong rather than stale, and
``Authentication/replayOn401`` has nothing to turn to without one.

## Refreshing Ahead of a Send

Before the token is read, the client refreshes proactively when ``Authentication/refreshThreshold``
is set, the provider reports a ``TokenProvider/timeUntilExpiry``, that lifetime is at or below the
threshold, an expired credential included, and an ``Authentication/refresher`` exists.

```swift
Authentication(provider: store, refresher: refresher, refreshThreshold: .seconds(30))
```

Size the threshold to the request's expected duration plus clock slack, so that a token valid at
send time is still valid when the server checks it. A proactive refresh that fails fails the request
with the refresher's own error, and nothing is sent.

## Refreshing After a 401

A `401` on an authenticated request, with ``Authentication/replayOn401`` on and a refresher present,
refreshes once and replays the same request once with whatever the provider then holds.

```swift
// A server whose 401 means something other than an expired credential.
Authentication(provider: store, refresher: refresher, replayOn401: false)
```

The replayed response is interpreted like any other, so a second `401` is
``TransportError/httpStatus(body:code:headers:)``. A `401` after a proactive refresh still earns that
one reactive refresh, because the replay path reasons about the token it actually sent. A replay is
not a retry attempt: it happens inside one attempt, so the retry policy in <doc:RequestPolicies>
counts the pair as one.

A `401` at the end of a redirect chain earns the same treatment, and the replay starts from the
request as resolved rather than from the hop that refused it. When the chain had crossed origins,
that means the refreshed token reaches only a same-origin hop: the refresh is wasted, never exposed.

## One Credential, One Refresh

The refresh is single-flight across every request sent under one ``Authentication``, through one
client or any copy of it. Concurrent `401`s share one in-flight ``TokenRefresher/refresh()``, and a
request whose rejected token the provider has already replaced replays without refreshing at all.

```swift
// Eight callers, one refresh.
await withTaskGroup { group in
  for _ in 0..<8 {
    group.addTask { try? await client.execute(Request(path: "/me")) as Response }
  }
}
```

A refresh runs to completion even when the request that started it is cancelled, since an abandoned
refresh under refresh-token rotation would strand every other request. A failed refresh throws the
refresher's error, the original `401` discarded, and by the refresher's contract the provider still
holds what it held.

## Copies and Identity

An ``Authentication`` value made once and shared between clients is one credential. Copies of it
refresh on one gate, so a burst of `401`s across them produces one ``TokenRefresher/refresh()``, and
they coalesce with each other under one ``RequestOptions/coalescingKey``. Changing a rule on a copy,
``Authentication/replayOn401`` or ``Authentication/refreshThreshold``, keeps that sharing.

```swift
var admin = client
admin.authentication = Authentication(
  provider: adminStore,
  refresher: AdminRefresher(store: adminStore)
)
```

A value made again, even over the same provider, is another credential: it refreshes on a gate of
its own and never joins an exchange sent under the first. That is what `admin` above gets, and
assigning ``HTTPClient/authentication`` is the whole of it, because a coalesced flight is keyed by
the credential as well as by the key. A response fetched with someone else's token is not the
caller's answer, so a request sent under one value, under another, or anonymously is three flights
under one key. See <doc:GettingStarted> for how that plays out across copies of a client.
