# Streaming a Response

Read a body as it arrives: chunks, then lines, then records or events.

## Overview

``HTTPClient/stream(_:)`` is a method on every client and returns a ``StreamedBody``. Every client
can stream, because ``Transport/stream(_:body:options:)`` is the one method a transport must
implement; the client calls it directly. The decoders above the body are ordinary `AsyncSequence`
wrappers you compose by hand.

```swift
let body = try await client.stream(Request(path: "/events"))

for try await event in SSEDecoder(body) {
  handle(event)
}
```

``StreamedBody`` is the type every streamed body is read as. Its element is `Data`: one chunk,
whatever the transport delivered in one read, and nothing in the package splits, joins, or buffers
one. It wraps any `Sendable` sequence of `Data` and reads as one non-generic type, so a body can sit
in a property or cross an API without spelling the sequence beneath it. It buffers nothing and
starts no task: each read is one closure call into the boxed base iterator. Cancellation is
interpreted there, so a cancelled consumer sees ``TransportError/cancelled`` from its next read at
the latest and never a clean end, whatever the base does about cancellation.

Each decoder is generic over its base rather than over ``StreamedBody`` concretely, so nothing in
the chain is welded to anything else. ``LineSplitter``, ``SSEDecoder``, and ``NDJSONDecoder`` each
take any `AsyncSequence` of `Data` whose `Failure` is ``TransportError``, and the two decoders split
their chunks into lines through a ``LineSplitter`` of their own. Where a chunk boundary falls makes
no difference to what comes out: a line, a field, or a value split across two chunks decodes
intact. Wrapping an in-memory `AsyncStream<Data>` in a ``StreamedBody`` in place of the network is
what makes the whole chain testable without one.

## What the Client Does and Does Not Do

Streaming keeps the resolution, the credential rules, and the redirect rules of the buffered
path. The base-URL join, default header fields, attach-on-send, a `3xx` followed under
``HTTPClient/redirectPolicy`` with its body dropped unread, and the single-flight `401`
refresh-and-replay all work exactly as they do for `execute(_:)`. Three policies are absent:

- No retry. A second attempt cannot replay chunks a consumer has already read, so a stream is sent
  once whatever ``RetryPolicy`` the client carries. To try again, call ``HTTPClient/stream(_:)``
  again from the top, knowing what you already consumed.
- No coalescing. One sequence cannot be read by several callers, so ``RequestOptions/coalescingKey``
  is ignored here and each call makes its own request.
- No deadline. A body that keeps arriving is the point of streaming, so ``HTTPClient/timeout`` and
  ``RequestOptions/timeout`` are ignored here; the transport's own deadlines still apply.

A status outside `2xx` throws ``TransportError/httpStatus(body:code:headers:)`` carrying the first
64 KiB of the body. The status is known before the first chunk is delivered, so the client reads the
error body that far, truncates it exactly at the limit when the server sent more, and releases the
read, which is what tells the transport to stop fetching. A failure while those bytes are being read
ends the read as well, and whatever arrived stands: the status is the failure you are being told
about. A caller cancelled during the read is told ``TransportError/cancelled`` instead, as from any
other point in the call. The limit is fixed, not a knob, and no deadline covers the read, since none
covers a stream, so an error body that neither ends nor fills the limit parks the caller until the
transport's own deadline. Send the request through ``HTTPClient/execute(_:)->Response`` when the
whole error body matters.

An observer sees ``TransportObserver/willSend(_:)`` and ``TransportObserver/didReceive(_:)``, the
latter when the response becomes available, carrying the real status and no body preview, since
there are no bytes in hand to preview. ``TransportObserver/didFail(_:)`` is reported only for a
failure that happens before the sequence is returned. Once the sequence is yours, the body's end is
reported from your own read: the `next()` that returns `nil` or throws first reports
``TransportObserver/didFinishBody(_:)`` with a ``BodyEvent`` carrying the bytes your reads returned
and the failure, if any, ``TransportError/cancelled`` included. A body you drop before it ended
reports nothing.

## Cancelling a Read

A consumer whose task is cancelled sees ``TransportError/cancelled`` from its next read at the
latest, whatever the base does about cancellation. The base owns the wake-up, since an iterator is a
value under exclusive use by the call awaiting it, and ``StreamedBody`` owns the interpretation:

- A cancelled task is refused before the base is consulted.
- A chunk the base delivers is still returned, and the cancellation is reported on the following
  call.
- An end or a failure the base reports while the task is cancelled reads as `cancelled`.

The last rule is what stops a base that answers cancellation with a clean end, as `AsyncStream`
does, from passing cancellation off as the end of the data.

Once a read has returned `nil` or thrown, the iterator is finished: it releases the base and every
later read returns `nil`, and a failure is reported once rather than repeated. Dropping the iterator
before the body has ended releases the base's iterator the same way, so whatever was still fetching
the body sees its consumer go and can stop.

## Writing a Body to a File

A body too large to hold in memory is written as it arrives. Create the file, open a handle on it,
and write each chunk ``HTTPClient/stream(_:)`` delivers as it comes, so nothing larger than one
chunk is ever resident.

```swift
let destination = URL(filePath: "/tmp/export.ndjson")
FileManager.default.createFile(atPath: destination.path(), contents: nil)

let file = try FileHandle(forWritingTo: destination)
defer { try? file.close() }

let body = try await client.stream(Request(path: "/export"))
for try await chunk in body {
  try file.write(contentsOf: chunk)
}
```

The package ships no download entry point and no transport refinement that writes to disk. The loop
above is the whole of one.

## Out of Scope

Nothing reports progress. A reader knows how many bytes it has taken, having taken them, and the
expected total is a response header field: ``Transport/stream(_:body:options:)`` answers with a
``StreamedResponse`` carrying the complete fields, while ``HTTPClient/stream(_:)`` returns the body
alone. The sending direction has no such count. A large upload goes out as
``RequestBody/file(_:contentType:)``, whose bytes the transport reads from disk as it sends, and a
``MultipartForm`` encodes in memory before the send begins; neither offers a point at which the
bytes already written can be observed. A body supplied as a stream, which is what upload progress
would measure, is not part of the package.

Background `URLSession` transfers are out of scope. A background task delivers its result to a
delegate after the process has been relaunched, and every entry point here awaits its answer in
place, so the two do not meet. A transfer that has to outlive the app belongs to `URLSession`
directly.

## Lines

``LineSplitter`` scans each chunk and splits on `\n`, treating a `\r` immediately before one as
part of the terminator and a `\r` anywhere else as data. The decision is never taken on a `\r`
alone, so a CRLF arriving as two separate chunks is the ordinary case. Only the bytes of a line the
chunk did not finish are carried over to the next one, so a line split across two chunks is yielded
once, whole, and a chunk holding several lines yields each in order.

A blank line is emitted, because SSE frames on them. A trailing unterminated tail is emitted when
the base ends cleanly, because you can drop one but could not recover one that had been swallowed.
Nothing is emitted for a stream that ends on its terminator.

`maxLineLength` bounds the carry-over and is unbounded by default. The first byte past the limit
throws ``TransportError/transport(kind:underlying:)`` of kind ``TransportFailureKind/other``,
carrying ``LineSplitterFailure/lineTooLong(limit:)``, without waiting for a terminator, so a line
that will never end is reported instead of silently truncated. The limit counts a line's own bytes,
so neither terminator counts against it. The failure type is public so that
`error.underlying as? LineSplitterFailure` tells a limit you set apart from a network failure you
did not. ``SSEDecoder`` and ``NDJSONDecoder`` take the same parameter and hand it to the
``LineSplitter`` they read through.

The element is ``Line``, which is `[UInt8]` with the terminator removed and nothing validated. It
has no `span` or `utf8Span` member of its own: a member handing back a borrow of its own storage
would need a lifetime annotation this package does not spell, so the borrow is taken in the scope
that reads it.

```swift
for try await line in LineSplitter(body, maxLineLength: 1 << 20) {
  let text = try UTF8Span(validating: line.bytes.span)
  handle(String(copying: text))
}
```

## Records

``NDJSONDecoder`` reads newline-delimited JSON. You name the value type as an initializer argument
instead of in angle brackets, because the type is generic over its base as well and Swift cannot
spell only some of a generic type's parameters.

```swift
struct Record: Decodable, Sendable {
  let id: Int
}

let body = try await client.stream(Request(path: "/records.ndjson"))
let records = NDJSONDecoder(body, decoding: Record.self)

for try await record in records {
  handle(record)
}
```

A line carrying nothing a decoder could read, meaning no bytes or only the tab, line feed, carriage
return, and space that JSON counts as whitespace, is skipped, since writers put blank lines between
records and at the end of a stream. Every other line goes to the decoder whole, and a line the
decoder rejects ends the sequence with ``TransportError/decode(underlying:)`` instead of being
skipped, so schema drift reaches you and a stream cut off mid-record becomes a decode failure. The
`JSONDecoder` is injected and defaults to a plain one, so key-decoding strategies are yours.

## Events

``SSEDecoder`` reads `text/event-stream` and follows the WHATWG event-stream grammar: fields
accumulate, a blank line dispatches them, a leading `:` is a comment, the first `:` separates a
field name from its value with one following space belonging to the framing, an unknown field name
is ignored, and a frame the stream ended in the middle of is discarded.

``ServerSentEvent`` carries ``ServerSentEvent/data``, ``ServerSentEvent/event`` (defaulting to the
grammar's own `"message"`), ``ServerSentEvent/id``, and ``ServerSentEvent/retry``. Two things about
that type are worth knowing before reading a log of events.

- ``ServerSentEvent/id`` and ``ServerSentEvent/retry`` are the stream's state, not the frame's. They
  are reported as the values in force when the event was dispatched, because the grammar keeps both
  across frames. An id may therefore repeat across several events, and a frame carrying nothing but
  a reconnection time dispatches no event at all while still changing what later events report. An
  `id` field with an empty value clears it and reads back as `nil`.
- ``ServerSentEvent/retry`` is reported, and ``SSEDecoder`` itself never acts on it. ``EventSource``
  does; see Reconnecting below.

This decoder is stricter than the grammar in one respect. The grammar decodes the stream as UTF-8
with replacement, and this one ends the sequence with ``TransportError/decode(underlying:)``
carrying a `UTF8.ValidationError`. A replacement character cannot be told from one the server meant
to send, so replacement would give you corrupted text with nothing to act on. Validation is uniform,
comments included, because the grammar puts the requirement on the whole stream.

## Reconnecting

An event stream is meant to outlive any one connection, and ``HTTPClient/stream(_:)`` sends once.
``HTTPClient/events(_:maxLineLength:reconnectDelay:)`` returns an ``EventSource``, a sequence of
``ServerSentEvent`` values that opens the request through ``HTTPClient/stream(_:)``, reads it as
``SSEDecoder`` does, and when the body ends or fails with a transport failure, waits and opens it
again with `Last-Event-ID` set to the last id the server sent. Nothing is sent until the sequence is
read, and each connection keeps the resolution, the credential rules, and the redirect rules.

```swift
for try await event in client.events(Request(path: "/events")) {
  handle(event)
}
```

The rules follow the WHATWG `EventSource` interface. The sequence reconnects after a clean end and
after ``TransportError/transport(kind:underlying:)``, at connect or part-way through the body, and
keeps doing so for as long as the consumer reads: there is no attempt limit, and cancelling the
reading task is how it ends. It ends on a status outside `2xx`, thrown as
``TransportError/httpStatus(body:code:headers:)``, since the server would refuse the request again;
cleanly on a `204`, which is how a server says there is nothing more to subscribe to; on
``TransportError/decode(underlying:)``, since a stream that is not UTF-8 would be as broken next
time; and on a line past `maxLineLength`, which is a limit you set rather than a network fault. A
consumer cancelled anywhere, parked on a body or waiting to reconnect, sees
``TransportError/cancelled`` and no further connection. The response's `Content-Type` is not
checked.

The wait before each reconnect is the server's last `retry` field, on the client's
``HTTPClient/clock``, and `reconnectDelay`, three seconds by default, until the server has sent
one. The id and the reconnection time are read from the stream as the grammar keeps them, so a
frame carrying only an `id` or a `retry` field and no data still counts, an `id` field with an
empty value clears the id so the next reconnect carries none, and an id set on one connection is
still sent after a connection that set none. A failed attempt that answers with a status outside
`2xx` reads up to 64 KiB of that body, with no deadline over it, before the failure is thrown.

A test drives the whole thing without a network or a wait: seed `MockTransport` with one answer
per connection, put a `RecordingClock` on the client, and advance it past the reconnect. The second
call the transport records carries `Last-Event-ID`, and the clock's `sleeps` holds the `retry` the
first answer sent.

## Writing a Transport

``Transport`` has one required method, ``Transport/stream(_:body:options:)``, which answers with a
``StreamedResponse``: the status and header fields, settled before the first chunk, and the body as
a ``StreamedBody``. The body arrives as a ``TransportBody``, already encoded, and the settings the
transport itself acts on as ``TransportOptions``. ``Transport/send(_:body:options:)`` has a default
that streams and drains every chunk into one `Data`, so a transport that streams buffers for free.
A transport with a cheaper buffered path overrides it, as `URLSessionTransport` does with the
session's own `data(for:)`, `upload(for:from:)`, and `upload(for:fromFile:)`.

``StreamedBody/init(_:mapFailure:)`` is how a transport adapts a foreign sequence without
`HTTPCore` learning anything about it. The closure turns the base's own failure into a
``TransportError``, so the `HTTPURLSession` transport maps `URLError` there and `HTTPCore` imports
no networking types at all.

```swift
let body = StreamedBody(source) { error in
  TransportError.transport(kind: .other, underlying: error)
}
```

Leaving the closure out supplies the default mapping instead: a `CancellationError` becomes
``TransportError/cancelled``, a `TransportError` passes through so a typed base is not wrapped
twice, and anything else becomes a transport failure of kind ``TransportFailureKind/other`` carrying
the original error.

A conformer promises one thing about the body: discarding it unread cancels whatever was still
fetching it. ``StreamedBody`` does its part by releasing the base's iterator when its own is dropped
before the body has ended, so whatever was still fetching the body sees its consumer go. That is
what leaves nothing running behind the client's non-2xx throw and behind a
`401` replay.
