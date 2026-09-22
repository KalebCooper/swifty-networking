# ``WebSocketURLSession``

Open explicitly owned Apple WebSocket connections using URLSession.

## Overview

Inject ``URLSessionWebSocketTransport`` into ``/WebSocketCore/WebSocketClient``.
The shared client supplies validation, authentication, deadlines, bounded receiving and sending,
and connection ownership.

```swift
import WebSocketCore
import WebSocketURLSession

let client = WebSocketClient(transport: URLSessionWebSocketTransport())
try await client.withConnection(to: endpoint) { socket in
  try await socket.send("subscribe")
  for try await message in socket.messages {
    handle(message)
  }
}
```

### Sessions and Requests

Each transport owns an ephemeral URLSession. Connections retain that session's owner; releasing
the last transport and connection invalidates it. Aborting one connection cancels its Foundation
task without stopping other connections. Task completion removes its delegate registry entry.
The shared core's external ownership token remains independent of callbacks and receive work.

Redirects, including same-origin redirects, are refused. Automatic cookie storage and credential
storage are disabled; explicit Cookie and Origin fields are allowed. Server trust and hostname
validation use the system defaults. There is no injected shared session or trust-bypass option.

A failed upgrade includes available HTTP status and fields. Authentication challenges do not
trigger Foundation credential replay. The shared client permits at most one eligible refresh and
new attempt after an observed 401; missing status never triggers refresh. Each adapter attempt
creates one URLSession task. Foundation may retry connection establishment internally.

### Messages and Lifetime

The adapter sets maximumMessageSize before resume. One shared receive pump reads whole messages
into the core inbox. It remains active while an application reader is cancelled or paused, allowing
control processing to continue. Inbox overflow is terminal rather than silently dropping messages.
These bounds exclude Foundation's private buffers, TCP/TLS buffers and temporary copies.

Ping completion comes from Foundation's pong callback. Cancelling a ping caller preserves its
physical probe and original deadline. Missing that deadline aborts the connection.

Close requests orderly shutdown and waits for backend completion within the shared deadline.
``/WebSocketCore/WebSocketClose`` and closeInfo contain backend-reported metadata. On a locally
initiated close, URLSession can report the requested code and reason even when the peer replies
differently or sends no close frame. Successful completion does not prove peer acknowledgement.
A close frame without a code is represented with a nil code.

The adapter has real-wire loopback coverage on macOS 27 and iOS 26.5 simulator. These fixtures
exercise HTTP upgrade, WebSocket frames, a locally trusted test CA, rejection of an untrusted CA,
hostname mismatch and cancellation during TLS. The public transport uses system trust; the test CA
is supplied only to an internal fixture and is never installed as a system root. Other Apple
platforms and physical-device lifecycle behavior require separate qualification. Connections are
not promised to survive backgrounding or run continuously on watchOS.

## Topics

### Connecting

- ``URLSessionWebSocketTransport``
