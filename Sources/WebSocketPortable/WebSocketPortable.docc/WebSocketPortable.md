# ``WebSocketPortable``

Open WebSocket connections with NIO and NIOSSL, bounded framing and explicit resource ownership.

## Overview

Enable the WebSocketPortable dependency trait and use ``NIOWebSocketTransport`` through
``/WebSocketCore/WebSocketClient``. The transport owns one reusable event-loop group and TLS context.
Individual sockets have independent cancellation. Call ``NIOWebSocketTransport/shutdown()`` when
the transport is no longer needed; it refuses new connects, terminates pending and open channels,
awaits their closure and releases the group. Repeated shutdown calls join the same cleanup.
Cancelling a shutdown waiter leaves cleanup running.

```swift
let transport = try NIOWebSocketTransport()
let client = WebSocketClient(transport: transport)
do {
  try await client.withConnection(to: endpoint) { socket in
    try await socket.send("subscribe")
    for try await message in socket.messages {
      handle(message)
    }
  }
} catch {
  try? await transport.shutdown()
  throw error
}
try await transport.shutdown()
```

### Protocol and Resource Limits

The shared client owns validation, authentication and deadlines. It refuses redirects and replays
credentials only after a known eligible HTTP 401. Unknown failures never synthesize status.
TLS verifies certificates and hostnames against NIOSSL's default platform trust roots; no public
verification bypass or injected event-loop group is provided.

The transport delivers complete messages into the shared bounded inbox, without another application
queue. NIO framing bounds each physical frame to the larger of the message limit and 125 bytes,
capped at UInt32.max bytes; accumulated messages respect
``/WebSocketCore/WebSocket/Options/maxMessageBytes``. Control frames can carry up to 125 bytes
even when the application message limit is smaller. Messages may contain at most 1,024 fragments,
including empty fragments. This is a resource policy, not an RFC requirement.
The opening response head has a 16 KiB total limit and a 100-field limit.

The adapter rejects masked server frames, reserved bits/opcodes, noncanonical lengths, invalid
continuations, invalid UTF-8, malformed close payloads, unoffered subprotocols and extensions.
Every client frame draws a fresh unpredictable mask. Ping responses run on the event loop while
application consumption stalls. Control writes also honor channel writability; resource exhaustion
terminates the connection rather than building an unbounded outbound control queue.

Resource limits report bufferOverflow or messageTooLarge through ``/WebSocketCore/WebSocketError``;
protocol violations remain distinct. Inbox overflow uses the shared bounded-close policy. Abrupt EOF
is a failure. Empty peer close and raw application codes are preserved. Close completion reports
backend metadata and is not an application acknowledgement.

The limits bound package payloads and frame assembly, not total process memory. Kernel sockets,
TLS buffers, NIO allocation capacity and temporary copies remain outside inbox accounting.
There is no compression, reconnect, automatic heartbeat or application acknowledgement protocol.

### Platform Qualification

Linux, macOS 27 and iOS 26.5 simulator loopback coverage exercises plaintext and trusted TLS,
untrusted-certificate and hostname rejection, cancellation during TLS and partial writes, raw
protocol fixtures and resource shutdown. These runs include NIO 2.102.0 and NIOSSL 2.37.4.
Android emulator execution, Android application trust-root discovery and application network-policy
behavior remain unqualified. Other Apple platforms and physical devices were not exercised.
Linux success does not establish Android support.

## Topics

### Client Transport

- ``NIOWebSocketTransport``
