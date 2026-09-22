# ``WebSocketHummingbird``

Adapt accepted Hummingbird WebSocket connections to the shared ``/WebSocketCore/WebSocket``
connection API.

## Overview

Enable the WebSocketHummingbird trait on macOS or Linux. Create one
``HummingbirdWebSocketAdapter`` for the server's connection options and install its
``HummingbirdWebSocketAdapter/configuration`` on Hummingbird's HTTP/1 WebSocket upgrade builder.
Perform authentication and authorization in Hummingbird's upgrade decision before calling
``HummingbirdWebSocketAdapter/prepare(channel:negotiatedSubprotocol:)``.

The upgrade decision has access to Hummingbird's public channel. The adapter uses it to observe
matching pong and raw close frames before the upstream message reader consumes them. Hummingbird's
router WebSocket convenience does not expose that channel, so use the lower level upgrade builder
for this adapter. The application still owns its middleware and request decisions.

```swift
import Hummingbird
import HummingbirdWebSocket
import WebSocketCore
import WebSocketHummingbird

let adapter = try HummingbirdWebSocketAdapter()
let app = Application(
  router: Router(),
  server: .http1WebSocketUpgrade(configuration: .init(ws: adapter.configuration)) {
    request, channel, _ in
    guard request.headerFields[.authorization] == "Bearer expected" else {
      return .dontUpgrade
    }
    let scope = try await adapter.prepare(channel: channel)
    return .upgrade([:]) { inbound, outbound, _ in
      try await scope.withConnection(inbound: inbound, outbound: outbound) { socket in
        for try await message in socket.messages {
          // Process and commit application state before sending its response.
          try await socket.send(message)
        }
      }
    }
  })
```

The example echoes messages only to show where an application response belongs. Applications
choose their own acknowledgement and ordering rules. No listener, event-loop group, authentication
scheme, reconnect loop or application protocol is supplied by this product.

## Connection Behavior

``HummingbirdWebSocketScope/withConnection(inbound:outbound:isolation:operation:)`` creates the
same ``/WebSocketCore/WebSocket`` handle used by client transports. The shared session owns the
bounded message inbox, one send FIFO, ``/WebSocketCore/WebSocket/SendOperation`` results, admission
and failure policies, and operation deadlines. The scope closes only its accepted channel and waits
for its physical reader before returning. A socket that escapes the handler is terminal.

Use the adapter's server configuration with the same options passed to its initializer. It disables
Hummingbird's independent automatic ping, enables UTF-8 validation, and derives the frame and close
limits. Control frames require up to 125 bytes even when the application message limit is smaller.
Completed messages are checked again by the shared inbox. Hummingbird and NIO retain their own
bounded channel buffers outside the inbox's accounting.

The server does not use ``/WebSocketCore/WebSocket/Options/connectTimeout``, client credentials,
redirect handling or the portable client's event-loop group. Handler return, error or cancellation
terminates only that connection. A completed send reports backend write acceptance, not application
delivery; close metadata does not prove peer acknowledgement.

## Topics

### Accepted Connections

- ``HummingbirdWebSocketAdapter``
- ``HummingbirdWebSocketScope``
