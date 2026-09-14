# Paginating a Response

Follow a rule you supply from one page to the next, each page its own request through the whole
client pipeline.

## Overview

``HTTPClient/pages(_:as:next:)`` returns a ``PageSequence``, which fetches a first page and then,
after decoding each page, asks a rule you supply where the following page lives, as a ``NextPage``.
Nothing is sent until the sequence is read.

An API points at its next page one of two ways: a `Link` header field, read with ``WebLink``, or
something the response hands back in its body, most often a cursor.

```swift
// A `Link` header field.
let issues = client.pages(Request(path: "/repos/o/r/issues"), as: [Issue].self) { page, _ in
  WebLink.links(in: page.headers)
    .first { $0.relations.contains("next") }
    .map { .link($0.target) }
}

for try await page in issues {
  handle(page.value)
}
```

```swift
// A cursor in the body.
let items = client.pages(Request(path: "/items"), as: ItemPage.self) { page, request in
  page.value.nextCursor.map { cursor in
    var next = request
    next.query = [QueryItem(name: "cursor", value: cursor)]
    return .request(next)
  }
}
```

`next` receives the request that produced the page, with ``RequestOptions/coalescingKey`` already
cleared (see Coalescing below), so a derived request is a copy of it with one field changed.

## Following a Link

A ``NextPage/link(_:)`` is a URI reference, resolved the way RFC 3986 resolves a relative reference,
against the URL of the response that carried the page, after any redirect, not the request you
wrote. That is what lets a relative target in a `Link` field read the way the server wrote it,
whatever address actually answered the request.

The page is then fetched with `GET` and no body, keeping the header fields and options of the
request that produced the current page; `Content-Type` and `Content-Length` are dropped, as they
are on a redirect to `GET`. A reference that does not resolve to an absolute URL still lets the
current page return; the next read throws ``TransportError/transport(kind:underlying:)`` with
``TransportFailureKind/badURL``.

The request ``PageSequence/next`` is handed after a ``NextPage/link(_:)`` page keeps the path and
query of the last request that was not itself a link, not the link's own target, so a cursor-style
`next` reading that request still sees where the sequence actually started.

## Credentials Across Origins

A page on another origin, a cross-origin ``NextPage/link(_:)`` included, goes without
`Authorization`, `Cookie`, `Proxy-Authorization`, and the field ``HTTPClient/authentication``'s
scheme writes into, whether you set the field yourself, set it in ``HTTPClient/defaultHeaders``, or
the client attached it, the same rule a redirect to another origin follows (see
<doc:RequestPolicies>). Every other header field travels with every page exactly as you wrote it.

## What Each Page Gets

Every page is its own logical request, sent through the whole pipeline: its own correlation
identifier, retries, deadline, redirects, and the credential and observer rules of any other
request. A request that sets ``HTTPClient/correlationIDField`` itself keeps that value, so every
page fetched from it reuses the same identifier; otherwise each page gets a fresh one.

## Coalescing

The first page is sent with its ``RequestOptions/coalescingKey``. Every page after it is sent with
the key cleared, and the request handed to `next` already has it cleared. A key names one response,
and a later page sharing the first page's key with another iteration would join that iteration's
unrelated page.

## Ending the Sequence

`nil` from `next` ends the sequence after the page just decoded is returned. Any thrown error ends
it too: the iterator is finished and every later read returns `nil`. There is no page limit; stop
reading with `break` once you have enough. A ``NextPage/link(_:)`` that resolves to the current
page's own URL fetches that page again, so a rule that names the current page by mistake loops
rather than stopping.

## Cancellation

A consumer whose task is cancelled sees ``TransportError/cancelled`` from its next read, and no page
is fetched on a cancelled task.
