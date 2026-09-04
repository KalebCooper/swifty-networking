# Getting Started

Build a client over a transport, send a request, and decode what came back.

## Overview

``HTTPClient`` is the entry point. It is a `Sendable` struct that holds its transport as
`any Transport` and its clock as `any Clock<Duration>`, so it is spelled the same wherever it is
stored or injected, and you construct one where its collaborators are and pass it around like any
other value. There is no shared instance to configure and no registry to look anything up in.

Two things are required: a base `URL` and something that sends. On Apple platforms the sender is
`URLSessionTransport`, from the `HTTPURLSession` product, and that product adds an initializer that
builds it for you from a `URLSession`, so a client over the shared session is
`HTTPClient(baseURL:)` alone. On Linux and on Android the sender is `AsyncHTTPClientTransport`,
from the `HTTPPortable` product, behind the trait of the same name; build it, pass it as
`transport:`, and shut it down once after the last request.

```swift
import HTTPCore
import HTTPURLSession

struct Profile: Decodable {
  let id: String
  let name: String
}

let client = HTTPClient(
  baseURL: URL(string: "https://api.example.com/v1")!,
  transport: URLSessionTransport()
)

let profile: Profile = try await client.execute(Request(path: "/me"))
```

Everything else on the initializer has a default, and the defaults are unopinionated: no retrying,
no credentials, no observer, a `ContinuousClock`, a plain `JSONDecoder` and `JSONEncoder`. A
client is given its collaborators rather than being registered with them, and a variant of one is a
copy with a property assigned, which the Deriving a Client section below covers. Every client
streams through the same transport; see <doc:Streaming>. What the client does with a credential is
<doc:Authenticating>, and what it does about deadlines, retries, redirects, and coalescing is
<doc:RequestPolicies>.

There are four entry points, and they differ only in what they do with a successful body. The typed
``HTTPClient/execute(_:)->R`` decodes it into a `Decodable` value,
``HTTPClient/execute(_:)->Response`` returns it untouched, the `execute(_:)` overload you annotate
with a ``DecodedResponse`` decodes it and keeps the header fields with it, and
``HTTPClient/executeExpectingNoContent(_:)`` discards it. All four interpret the status the same
way: anything outside `2xx` is ``TransportError/httpStatus(body:code:headers:)``, carrying the body
and header fields so you can read an error envelope without a second request.

## Sending a Body

``Request`` carries its payload as a ``RequestBody``, and the encoding happens at the moment of
sending, so the client's own encoder produces every JSON body it sends.

```swift
struct SignUp: Encodable, Sendable {
  let email: String
}

let created: Profile = try await client.execute(
  Request(
    body: .json(SignUp(email: "person@example.com")),
    method: .post,
    path: "/profiles",
    query: [QueryItem(name: "notify", value: "false")]
  )
)
```

``QueryItem`` percent-encodes both sides itself when the request is resolved, so a value is written
raw and never escaped twice. An item you already hold as a `URLQueryItem` converts with
``QueryItem/init(_:)``.

An endpoint that wants a form takes the same items as ``RequestBody/form(_:)``. They are encoded as
a query is, except that a space is `+` and a literal `+` is `%2B`, and the request goes out as
`application/x-www-form-urlencoded`.

```swift
let session: Token = try await client.execute(
  Request(
    body: .form([
      QueryItem(name: "grant_type", value: "refresh_token"),
      QueryItem(name: "refresh_token", value: token),
    ]),
    method: .post,
    path: "/oauth/token"
  )
)
```

Text fields and files together go out as ``RequestBody/multipart(_:)``. Build the ``MultipartForm``
part by part; it encodes as you append and holds the result in memory, so a large upload is better
sent as a file.

```swift
var form = MultipartForm()
form.append(name: "caption", value: "On the trail")
form.append(contentType: "image/jpeg", data: photo, filename: "trail.jpg", name: "photo")

try await client.executeExpectingNoContent(
  Request(body: .multipart(form), method: .post, path: "/photos")
)
```

Bytes you have already encoded go out as ``RequestBody/bytes(_:contentType:)`` under the media type
you name, and a file goes out as ``RequestBody/file(_:contentType:)``, which the transport reads
from disk as it sends. Every kind that carries a payload names the request's `Content-Type` when
neither the request nor the client's default header fields already carry one. A multipart body is
the one that names it either way: its media type carries the boundary the form minted, which no
field written by hand can name, so it replaces the field rather than deferring to it.

## Reading Header Fields Alongside the Body

Annotating an `execute(_:)` call with a ``DecodedResponse`` answers with the decoded body together
with the header fields and the status it arrived with. The body is decoded exactly as the typed
``HTTPClient/execute(_:)->R`` decodes it, through the same size rule, so a large one still parses
off the caller's executor.

```swift
let page: DecodedResponse<[Item]> = try await client.execute(Request(path: "/items"))

var conditional = Request(path: "/items")
if let version = page.headers[.eTag] {
  conditional.headers[.ifNoneMatch] = version
}
let refreshed: DecodedResponse<[Item]> = try await client.execute(conditional)
```

Reach for it where a header field is part of the answer rather than a detail of delivering it: an
`ETag` to send back as `If-None-Match`, a pagination cursor, a rate-limit budget. The status is
interpreted as it is everywhere else, so a `304 Not Modified` arrives as
``TransportError/httpStatus(body:code:headers:)`` rather than as a decoded value.

## Starting a Request That Cannot Be Lost

An ordinary `Task { … }` is scheduled, not started, so the enclosing scope can be torn down before
the request reaches the transport and the request never happens. `Task.immediate` runs the operation
synchronously on the calling actor up to its first real suspension, which is past the point where
the request has been given to the transport.

```swift
let inFlight = Task.immediate {
  let profile: Profile = try await client.execute(Request(path: "/me"))
  return profile
}

let profile = try await inFlight.value
```

This is the shape for a SwiftUI `.task` modifier, where the view can disappear in the same turn the
modifier fires. It is not a substitute for cancellation: cancelling `inFlight` still cancels the
request, and the client reports that as ``TransportError/cancelled``.

## Choosing a Session

`URLSessionTransport` defaults to `URLSession.shared`, which is the right answer for an app with no
reason to disagree. Pass a session of your own where the shared defaults are wrong for the API, most
often to keep credentials and cached responses out of storage shared with everything else in the
process.

```swift
let configuration = URLSessionConfiguration.ephemeral
configuration.httpCookieStorage = nil
configuration.httpShouldSetCookies = false
configuration.urlCache = nil
configuration.timeoutIntervalForRequest = 30
configuration.timeoutIntervalForResource = 300

let client = HTTPClient(
  baseURL: URL(string: "https://api.example.com/v1")!,
  session: URLSession(configuration: configuration)
)
```

That configuration is also where this transport's own deadlines are set, and where its cache lives.
The client's ``HTTPClient/timeout`` bounds a whole request above them, every attempt included, on
the client's clock. A request can override the cache for itself: ``RequestOptions/cachePolicy``
reaches the transport as ``TransportOptions/cachePolicy``, and `URLSessionTransport` sets the
matching `URLRequest.CachePolicy` on the request it sends.

## Deriving a Client

A client is a value. A variant that differs in a header field, a policy, a coder, or the base is a
copy with that property assigned:

```swift
var beta = client
beta.baseURL = URL(string: "https://beta.example.com/v1")!
beta.defaultHeaders[.accept] = "application/json"

let profile: Profile = try await beta.execute(Request(path: "/me"))
```

Every public stored property can be changed this way, ``HTTPClient/transport`` included, so a copy
pointed at another transport sends through it. Assigning ``HTTPClient/baseURL`` parses the new base
at once, and one that is not usable fails the copy's requests exactly as it would fail a client
built with it.

Copies share one coalescer, so copies that differ in base or default header fields still coalesce
under one ``RequestOptions/coalescingKey`` and the joiner receives the leader's response. The key is
a declaration that two requests are equivalent, so give copies whose responses must not be shared
different keys.

A credential is the exception, and it needs no help from the key. A flight is keyed by the
``Authentication`` the request goes out under as well as by the string, so assigning
``HTTPClient/authentication`` on a copy is enough:

```swift
var admin = client
admin.authentication = Authentication(
  provider: adminStore,
  refresher: AdminRefresher(store: adminStore)
)
```

`admin` now refreshes `adminStore` on that value's own gate rather than waiting on a refresh started
for the original's provider, and it never joins an exchange the original sent under the original's
credential or under none. Copies taken from `admin` afterwards carry the same value and share both.
Changing a rule on the value, ``Authentication/replayOn401`` or ``Authentication/refreshThreshold``,
changes nothing about that sharing; making a new `Authentication`, even over the same store, does.

A transport is the other exception. Assigning ``HTTPClient/transport`` gives the copy a coalescer of
its own, so a keyed request through it is never answered by an exchange the original sent through
the transport it was built over; copies taken afterwards share the new one.

A `JSONDecoder` and a `JSONEncoder` are reference types and a copy holds the same ones, so a copy
that needs different settings is given a fresh coder rather than configuring the one it inherited.

## A Base URL That Does Not Parse

``HTTPClient/baseURL`` is a `URL`, and it is split into its pieces when the client is constructed
and again whenever the property is assigned.
A `URL` that is not a usable base, one with a fragment or without a scheme and host, still gives you
a client and fails each request instead, with
`TransportError.transport(kind: .badURL, underlying: nil)`. The base's validity is the one
construction-time concern that surfaces at resolve, and it is reported before anything is sent.

The join is predictable. The request's path is appended to the base's, with a leading `/` supplied
when it is missing and the base's trailing `/` stripped. The base's own query comes first and the
request's is appended after it. Default header fields are applied first, then replaced by field name
from the request.
