# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## 1.0.0 - 2026-09-03

Initial release.

### HTTPCore

- `HTTPClient`, one value per API: a base `URL` joined to a `Request`'s string path and query,
  default header fields, JSON encoding and decoding, redirects, retries, a deadline, credentials,
  and observers, with one typed error, `TransportError`, on every entry point. Every entry point
  takes a `Request`, which carries its `body`, `headers`, `method`, `options`, `path`, and `query`.
  `HTTPClient` is not generic: it holds `any Transport` and `any Clock<Duration>`, and its one
  initializer takes `baseURL:` and `transport:` with everything else defaulted, `clock:` to
  `ContinuousClock()`. Its public stored properties are `var`, so a variant of a client is a copy
  with a property assigned: assigning `baseURL` parses the new base at once, and copies share one
  coalescer and one refresh gate, so copies that differ in base or in default header fields
  coalesce under one `coalescingKey` and the joiner receives the leader's response. Assigning
  `transport` gives the copy a coalescer of its own, so a keyed request through it is answered only
  by an exchange sent through that transport, and copies taken after the assignment share the new
  coalescer.
- `Authentication`, a credential source paired with the rules a client applies around it: a
  `provider`, an optional `refresher`, `refreshThreshold`, and `replayOn401`. It goes into
  `HTTPClient` as one `authentication:` argument and one `var`. `TokenProvider` supplies the
  credential and `TokenRefresher` renews it, ahead of expiry at `refreshThreshold` and on a `401`
  under one gate, which earns one refresh and one replay. Every copy of one `Authentication` value
  is one credential: copies refresh on that one gate and coalesce with each other, and changing a
  rule on a copy keeps that sharing; a value made again, even over the same provider, is another
  credential with a gate of its own.
- `Authentication.Scheme` and the defaulted `Authentication.scheme`, how the credential becomes a
  header field. `bearer`, the default, writes `Authorization: Bearer <token>`; `basic` writes
  `Authorization: Basic <token>`, the token being the base64 RFC 7617 defines; `field` writes the
  token unprefixed into the field it names. The provider holds one string with no prefix. Every
  other rule reads the same under every scheme: `requiresAuth` decides whether a credential goes
  out, a `401` earns one refresh and one replay, and a hop to another origin is sent without the
  field the client attached.
- `Authentication.basicCredential(password:username:)`, the credential
  `Authentication.Scheme.basic` sends, built from a user name and a password as the base64 of the
  two joined by a colon in UTF-8. Build it where you hold the pair and return it from
  `TokenProvider.currentToken()`. The user name must not contain a colon, which RFC 7617 forbids,
  and the value is returned as given, unchecked; a colon in the password is encoded like any other
  character.
- `RetryPolicy` and `BackoffSchedule`, driven by the client's injected `Clock`.
  `RetryPolicy.retryable` takes a `FailedAttempt`: the failure, the one-based ordinal of the
  attempt that threw it, and how long the request has been running on that clock, measured from
  just before the first send and covering every hop, replay, and wait since. The default is
  `{ $0.failure.isTimeout }`. When the failure is a status whose `Retry-After` names a number of
  seconds, the client waits that long rather than the schedule's delay, jitter included, for
  whatever status the predicate retried; an HTTP-date or any other form is ignored and the schedule
  applies. A wait longer than the remaining deadline is cut short by it. `RetryPolicy` carries
  `backoff`, `maxAttempts`, and `retryable`; `RetryPolicy.disabled` is the client's default.
- `HTTPClient.timeout` and `RequestOptions.timeout`, a deadline for a whole request on the client's
  clock: every attempt and the waits between them, the request's own value taking the client's
  place. Past it, the request throws `TransportError.transport(kind: .timedOut, underlying: nil)`,
  the exchange is cancelled, and the retry predicate is never asked. A coalesced caller's deadline
  detaches that caller alone and the shared exchange finishes for the rest. `stream(_:)` applies no
  deadline. `nil`, the default on both, sets none. `RequestOptions` carries `cachePolicy`,
  `coalescingKey`, `redirectPolicy`, `requiresAuth`, `retryPolicy`, and `timeout`, and each field a
  request sets takes the client's place for that request alone. `CachePolicy` is the
  transport-neutral hint a request may carry, `cacheElseLoad`, `cacheOnly`, `ignoreCache`,
  `revalidate`, or `standard`, which each transport maps onto whatever cache it owns, treating a
  case it has no distinct behaviour for as `standard`.
- `RedirectPolicy`, with `HTTPClient.redirectPolicy` and `RequestOptions.redirectPolicy`, the
  request's own taking the client's place. `follow`, the default, sends the request again to the
  `Location` a `301`, `302`, `303`, `307`, or `308` names, resolved as RFC 3986 resolves a
  reference against the URL the `3xx` came from; `sameOrigin` follows only while the scheme, host,
  and port stay the request's; `never` follows nothing. The three older statuses send `GET` with no
  body and without `Content-Type` and `Content-Length`, a `HEAD` staying `HEAD`; the two newer keep
  the method and the body. A hop to another origin goes out without the field the client attached
  under `Authentication.scheme`. Each hop is a send the observer sees under the same attempt
  ordinal, a `3xx` body is dropped unread, twenty hops are followed, and a redirect the policy
  stops at is returned as the response, so every entry point throws it as `httpStatus` with
  `Location` in its headers. A transport follows nothing on its own.
- Request coalescing under a per-request `coalescingKey`, keyed by the credential as well: a
  request sent under one `Authentication`, under another, or anonymously shares an exchange with
  none of the others, so a caller is never handed a response fetched under someone else's token.
- `TransportObserver`, whose events carry the target `URL` and a correlation identifier per logical
  request, and whose four requirements, `willSend(_:)`, `didReceive(_:)`, `didFail(_:)`, and
  `didFinishBody(_:)`, carrying `RequestEvent`, `ResponseEvent`, `FailureEvent`, and `BodyEvent`,
  each have a do-nothing default. `didFinishBody(_:)` and `BodyEvent` are reported once from the
  consumer's own read when a streamed body ends or fails, with the bytes the reads returned, the
  request's correlation identifier, and the failure if there was one, `cancelled` included. Every
  transport's body reports it, a body dropped before it ended reports nothing, and a `stream(_:)`
  call that throws reports nothing past `didReceive` or `didFail`.
- `LoggingObserver`, behind the off-by-default `Logging` trait, a `TransportObserver` that writes
  every event to a swift-log `Logger` you supply. Each kind carries its own level, `debug` for a
  send, `info` for a response, `error` for a failure, and `debug` for a streamed body's end, and
  each is a defaulted field you can raise or lower. The attempt, the credential flag, the
  correlation identifier, the method, the target, the send's own duration in whole milliseconds,
  the status, and a body's byte count travel as metadata; a `TransportError` is interpolated into
  the message through its description. No line carries a header field, a body byte, or a credential
  the client attached, and the observer asks for no body preview; a credential the request itself
  carries in its target, in the query string or the userinfo, appears there as it would in any
  other record of the request. A status the client rejects is a response, so a `500` is logged at
  the response level. Its reference is in `HTTPCore`'s documentation only when the trait is
  enabled, so the published site does not carry it.
- `Transport`, one protocol with one required method, `stream(_:body:options:)`, and
  `Transport.send(_:body:options:)` defaulted to call it and drain every chunk into one `Data`,
  throwing a failure the body reports part-way through, so a transport implements the streaming
  method alone and buffers for free. `TransportBody` and `TransportOptions` are what a transport
  receives alongside the request: the body as `bytes(Data)`, `file(URL)`, or `none`, already
  encoded and named by a `Content-Type` field on the request, and the settings the transport itself
  honours, today `cachePolicy` alone. `StreamedResponse` carries its body as a `StreamedBody`.
- `RequestBody`, a request's body as `bytes(_:contentType:)`, `file(_:contentType:)`, `form(_:)`,
  `json(_:)`, `multipart(_:)`, or `none`, encoded by the client and naming the request's
  `Content-Type`.
- `RequestBody.file(_:contentType:)`, a file the transport reads from disk as it sends, so the file
  is never loaded whole.
- `RequestBody.form`, a body of `QueryItem` values sent as `application/x-www-form-urlencoded`. The
  pairs are encoded by the rule a query string uses, with a space rendered as `+` and a literal `+`
  as `%2B`; a `nil` value sends its name alone, and the pairs are joined with `&` in the order
  given. The body names the request's `Content-Type` unless the request or the client's default
  header fields already carry that field.
- `RequestBody.multipart` and `MultipartForm`, a `multipart/form-data` body built part by part with
  `append(name:value:)` and `append(contentType:data:filename:name:)`. The form encodes as it is
  appended and holds the result in memory, frames each part per RFC 7578 with CRLF line ends, and
  percent-encodes a quotation mark or a line break in a name or a file name and a line break in a
  part's media type. `MultipartForm.init()` draws a boundary of 32 letters and digits at random;
  `MultipartForm.init(boundary:)` takes the one you name, as given. The body's `Content-Type` names
  that boundary and overrides a field the request or the client's default header fields carry, the
  one body that wins over a field written by hand.
- An `HTTPClient.execute(_:)` overload returning `DecodedResponse`, a decoded body carried together
  with the header fields and the status it arrived with, for an `ETag` to send back, a pagination
  cursor, or any other header-carried metadata. It decodes through `Response.decode(_:with:)`, so
  the client's size rule applies, and returns the result as `sending`. A status outside `2xx`
  throws `TransportError.httpStatus` as every other entry point does. One method name carries three
  results, a decoded value, a `DecodedResponse`, and the raw `Response`, and the type the call is
  annotated with picks between them.
- `Response.decode(_:with:)`, the decode the typed `HTTPClient.execute(_:)` performs, on a response
  you took whole. It reads the body with the decoder you pass and applies the client's own size
  rule, a body at or below 16 KiB parsed where the caller is running and a larger one parsed off
  the caller's executor, and returns the value as `sending`. A body that is not the type asked for
  throws `TransportError.decode`.
- Streaming as `AsyncSequence`. `HTTPClient.stream(_:)` calls the transport directly and hands back
  a `StreamedBody`, a `Sendable` sequence of `Data` chunks that fails only with `TransportError`,
  built from any `Sendable` sequence of `Data` through `init(_:mapFailure:)` and read as one
  non-generic type. The mapping defaults to passing a `TransportError` through, reading a
  `CancellationError` as `.cancelled`, and wrapping anything else as
  `.transport(kind: .other, underlying:)`. It buffers nothing, starts no task, and costs one
  closure call per chunk; a cancelled consumer sees `.cancelled` and never a clean end, and
  dropping the iterator mid-body releases the base's iterator so whatever was fetching the body can
  stop. A response outside `2xx` throws `TransportError.httpStatus` carrying the first 64 KiB of
  the error body: the client reads that far, truncates exactly at the limit when the server sent
  more, and releases the read there, which stops the transport fetching the rest. A failure while
  those bytes are being read ends the read too and whatever arrived stands, and a caller cancelled
  during the read leaves with `cancelled`. The limit is fixed rather than a knob, and no deadline
  covers the read, since none covers a stream.
- `LineSplitter`, `NDJSONDecoder`, and `SSEDecoder`, each reading chunks: each takes any sequence
  of `Data` that fails with `TransportError`, and the two decoders split lines through a
  `LineSplitter` of their own, so a decoder is built over a body directly, as `SSEDecoder(body)`.
  Where a chunk boundary falls makes no difference: a line, a field, or a value split across two
  chunks decodes intact. `maxLineLength` on `SSEDecoder` and `NDJSONDecoder` is handed to the
  `LineSplitter` each reads through, so the bound on what one line may gather is set where the
  decoder is built; the default, `nil`, is unbounded.
- `EventSource` and `HTTPClient.events(_:maxLineLength:reconnectDelay:)`, a sequence of
  `ServerSentEvent` values that reconnects on its own. Each connection is a `stream(_:)` call read
  through `SSEDecoder`; when the body ends cleanly or fails with `TransportError.transport`, at
  connect or part-way through, the sequence waits the server's last `retry` on the client's clock,
  or `reconnectDelay`, three seconds by default, until the server has sent one, and re-issues the
  request with `Last-Event-ID` set to the last id the server sent. An `id` or `retry` sent in a
  frame with no data counts, an empty `id` clears the id, and an id survives a connection that set
  none. There is no attempt limit; cancelling the reading task ends the sequence with `cancelled`
  from anywhere, parked on a body or waiting to reconnect. A status outside `2xx` ends it with
  `httpStatus`, a `204` ends it cleanly, and a line that is not UTF-8 or is past `maxLineLength`
  ends it with that failure.
- `ContentTypeSniff`, which names a body as `empty`, `gzip`, `html`, `jpeg`, `json`, `pdf`, `png`,
  `xml`, or `unknown`. A binary signature is read at the body's first byte and a text signature
  after any leading whitespace, so a body that begins with a newline can still be recognised as
  markup while one that begins with a space is not a gzip member.
- A DocC catalog with Getting Started, Concurrency Posture, Error Model, Streaming, Testing,
  Observations, Authenticating a Request, and Request Policies articles. Authenticating a Request
  carries attaching and refreshing a credential and what makes two credentials one; Request
  Policies carries deadlines, retries, `Retry-After`, redirects, and coalescing. Each type's own
  documentation states its rule once and links to the article.

### HTTPURLSession

- `URLSessionTransport`, buffered and streaming, with `URLError` codes mapped onto
  `TransportFailureKind`. The `URLError` itself travels in a `URLSessionTransportFailure`, whose
  `code` reads through to it and whose `urlError` holds it exactly as `URLSession` reported it, and
  whose description names the code and reduces the failing URL to scheme, host, and path, dropping
  the query, the fragment, and any user or password, so the line is safe to log. A response that is
  not an `HTTPURLResponse`, or whose status is outside the range a status can take, fails with
  `URLSessionResponseFailure`, `notHTTP(responseType:url:)` or `unrepresentableStatus(code:url:)`,
  which redacts its URL the same way. It carries its own `send(_:body:options:)` alongside
  `stream(_:body:options:)`.
- `stream(_:body:options:)` feeds the body from a delegate of the task's own, so each chunk is
  handed on exactly as the loading system delivered it, and a failure after the response reaches
  the reader through the body after every chunk delivered before it. The body is buffered only as
  far as the reader is behind: chunks not yet taken are held up to 512 KiB, beyond which the task
  is suspended, and it is resumed once they drain to 128 KiB. Dropping the body cancels the task,
  and so does cancelling a caller parked on the response.
- `HTTPClient.init(authentication:baseURL:clock:correlationIDField:correlationIDGenerator:decoder:defaultHeaders:encoder:observer:redirectPolicy:retryPolicy:session:timeout:)`,
  which builds the `URLSessionTransport` over `session` for you, so a client over the shared
  session is `HTTPClient(baseURL:)`.
- A `TransportBody.file` sent from disk on both paths: buffered through
  `URLSession.upload(for:fromFile:)`, streamed as an `httpBodyStream` on the file with its length
  announced, so neither path loads the file whole and both put the same request on the wire. A
  streamed file body is opened again when the loading system asks for the body a second time.
- `TransportOptions.cachePolicy` set as the matching `URLRequest.CachePolicy` on the request the
  transport sends; `nil` leaves the session configuration's own.
- The loading system's own redirects refused on both paths, through a per-task delegate, so a `3xx`
  reaches the client and `HTTPClient.redirectPolicy` is the one thing that follows one.

### HTTPPortable

- `AsyncHTTPClientTransport`, behind the off-by-default trait of the same name, so `HTTPCore` sends
  on Linux and on Android. It sends through an AsyncHTTPClient `HTTPClient` it builds from the
  configuration you pass, with redirects disallowed so `HTTPClient.redirectPolicy` stays the one
  thing that follows one, and must be shut down once through `shutdown()`; a transport released
  without one traps inside AsyncHTTPClient in a debug build and leaks its connections and event
  loops in a release build. A streamed body is read through a bounded buffer, and dropping an
  unread `StreamedResponse` cancels the request and closes its connection. A `TransportBody.file`
  is streamed from disk through SwiftNIO's file-system module with its size announced.
  `HTTPClientError` codes and the SwiftNIO channel and connection errors map onto
  `TransportFailureKind`, a refused host reads as `connectivity`, and a header field name or a
  status this package cannot represent fails the response with `AsyncHTTPClientResponseFailure`.
  `TransportOptions.cachePolicy` has no effect, because the client keeps no cache.
- A DocC catalog of its own, which builds only with the trait enabled, so the published site does
  not carry it.

### HTTPTesting

- `MockTransport`, a `Transport` a client is built over, answering every request from one FIFO
  queue and one path-keyed handler table, whichever surface the caller uses. `MockTransport.Answer`
  is what both hold: a status, header fields, and a body built afresh for each delivery, so one
  seeded answer serves a burst and every caller reads the body whole. An `Answer` is built from a
  `Response`, from the chunks a body arrives in with an optional failure ending them, or from a
  closure building a `StreamedBody`. `init(answers:results:)` queues `results` ahead of `answers`.
  Every seeded outcome is a `Result<Answer, TransportError>`, so a failure is seeded where an
  answer would be: `enqueue(_:)` takes one, and the handler `setHandler(forPath:handler:)`
  registers returns one. A handler is matched against the request path without its query string, so
  a handler registered for `/me` answers a request carrying query items. Each seeded chunk is
  delivered as one element of the body, an empty one included, so a test places a chunk boundary
  exactly where it wants one. A buffered call takes the protocol's default drain over
  `stream(_:body:options:)`, so it is recorded once and fails with `TransportError.cancelled` when
  it is read under cancellation, as a live transport's does. An unanswered call fails with
  `MockTransportFailure.noCannedResponse`, and `MockTransport.Call` records the `options` alongside
  the body and the request.
- `RecordingTokenProvider`, one `Mutex`-backed value that is both a `TokenProvider` and a
  `TokenRefresher`, so the same instance goes in as both collaborators. It holds the token and the
  remaining lifetime a test seeds, answers each refresh with the next seeded outcome, installing a
  success and throwing a failure with the credential untouched, and counts every refresh asked for
  in `refreshes`. `install(timeUntilExpiry:token:)` sets the credential from the outside, and a
  refresh past the last seeded outcome fails with `RecordingTokenProviderFailure.noSeededOutcome`.
- `RecordingClock`, a `Clock` a test advances by hand.
- `RecordingObserver`, a `TransportObserver` that records every event it is sent, a streamed body's
  end among them as `finishedBody`.
- `StubURLProtocol`, a `URLProtocol` subclass that answers a real `URLSession` from canned data
  (Apple platforms only).
- `Fixtures`, a namespace of `static` functions that build a JSON body for a request or a response.

### Platforms

- Swift 6.2 tools, Swift 6 language mode. iOS, macOS, tvOS, visionOS, and watchOS 26.
- `HTTPCore`, `HTTPTesting`, and `HTTPPortable` build and test on Linux and on Android. The Linux
  lane runs in a `swift:6.3-noble` container and the Android lane on an x86_64 emulator on Swift
  6.3.3, both on every push to `main` and every pull request, both with the `HTTPPortable` and
  `Logging` traits enabled, and the Linux lane runs the suite a second time under the default trait
  set, so what a consumer who asks for no trait gets is compiled and tested on every run.
- `AsyncHTTPClientTransport` is the transport on Linux and on Android. `HTTPURLSession` is
  Darwin-only and compiles to an empty target on both.
- Two traits, both off by default. `HTTPPortable` adds async-http-client 1.36.1 and swift-nio
  2.102.0, and `Logging` adds swift-log 1.15.0. A default consumer resolves neither stack and
  fetches swift-http-types alone.
