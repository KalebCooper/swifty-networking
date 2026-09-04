# ``HTTPPortable``

A transport over AsyncHTTPClient, so `HTTPCore` sends on Linux and on Android.

## Overview

`HTTPPortable` binds ``/HTTPCore/HTTPClient`` to SwiftNIO's networking stack. It ships one
``/HTTPCore/Transport``, ``AsyncHTTPClientTransport``, which sends a request through an
AsyncHTTPClient `HTTPClient` it builds and owns, converts the response, and maps a failure onto
``/HTTPCore/TransportError``. Every policy stays in `HTTPCore`: redirects are refused at the client
so ``/HTTPCore/HTTPClient/redirectPolicy`` is the only thing that follows one, a streamed body is
read through the same bounded buffer the `HTTPURLSession` transport uses, and a file body is
streamed from disk through SwiftNIO's file-system module.

The product is behind the `HTTPPortable` trait, off by default, so a package that does not enable
it never fetches or builds SwiftNIO. Enable the trait on the dependency, then import the module:

```swift
.package(url: "https://github.com/KalebCooper/swifty-networking.git", from: "1.0.0",
         traits: ["HTTPPortable"])
```

AsyncHTTPClient requires an explicit end of life. Build the transport where the client is built,
use it for as long as the client lives, and shut it down once, after the last request. A transport
released without ``AsyncHTTPClientTransport/shutdown()`` traps inside AsyncHTTPClient in a debug
build; in a release build it leaks its connections and event loops silently, which is the worse of
the two.

```swift
import HTTPCore
import HTTPPortable

let transport = AsyncHTTPClientTransport()
let client = HTTPClient(
  baseURL: URL(string: "https://api.example.com/v1")!,
  transport: transport
)

let profile: Profile = try await client.execute(Request(path: "/me"))

try await transport.shutdown()
```

## Topics

### The Transport

- ``AsyncHTTPClientTransport``
- ``AsyncHTTPClientResponseFailure``
