# ``HTTPCore``

Wire types, an error model, a policy layer, and streaming primitives, with no dependency on any
particular network stack.

## Overview

`HTTPCore` describes a request, sends it through a ``Transport`` you supply, and turns the response
into what you asked for. ``HTTPClient`` owns every policy: the base-URL join, default header fields,
body encoding, credentials, redirects, retries, coalescing, deadlines, status interpretation, and
decoding. It is one type rather than a generic one, holding its transport as `any Transport` and
its clock as `any Clock<Duration>`.

The module takes a base as a `URL` and reports each send's target as one, and it resolves a request
with its own join, so the path a request names is appended the same way on every platform. It
imports no `URLSession`, so it builds off Apple platforms, and builds and tests on Linux and on
Android. Pair it with the `HTTPURLSession` product for a transport backed by `URLSession`, with the
`HTTPPortable` product, behind the trait of the same name, for one backed by AsyncHTTPClient on
Linux and on Android, and with the `HTTPTesting` product for the test types that stand in for one.

```swift
let client = HTTPClient(
  baseURL: URL(string: "https://api.example.com/v1")!,
  transport: transport
)

let profile: Profile = try await client.execute(Request(path: "/me"))
```

## Topics

### Essentials

- <doc:GettingStarted>

### Design

- <doc:ConcurrencyPosture>
- <doc:ErrorModel>
- <doc:Observations>

### Credentials

- <doc:Authenticating>
- ``Authentication``
- ``TokenProvider``
- ``TokenRefresher``

### Policies

- <doc:RequestPolicies>
- ``BackoffSchedule``
- ``FailedAttempt``
- ``RedirectPolicy``
- ``RetryPolicy``

### Streamed Bodies

- <doc:Streaming>
- ``EventSource``
- ``StreamedBody``

### The Transport Boundary

- ``Transport``
- ``TransportBody``
- ``TransportOptions``

### Test Support

- <doc:Testing>
