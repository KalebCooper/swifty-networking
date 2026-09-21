# ``WebSocketCore``

Represent WebSocket messages, handshake inputs, close metadata and send configuration.

## Overview

This module provides foundational values. Live connections, transport protocols and network adapters
are not yet available. It does not change the HTTP client's transport or streaming contracts.

The package's shared opening-handshake policy validates requests before credential or backend work.
It preserves the original `Authentication` refresh identity, refuses redirects, and permits at most
one replay after an actual pre-upgrade HTTP 401 when replay is enabled and a refresher exists.
Unknown-status failures never trigger a refresh. One configurable deadline, 30 seconds by default,
covers credentials, refresh waiting and both handshake attempts. Cancellation or expiry releases
the caller without abandoning shared credential rotation; late successful connections are discarded.
This policy is available to package integrations, not through a public live client yet. Network
adapter behavior requires separate qualification.

``WebSocket/Message`` distinguishes text and binary data, including empty messages.
``WebSocket/CloseCode`` preserves raw application codes, and ``WebSocketClose`` represents an empty
peer close with a nil code. Neither constructing metadata nor receiving it proves a completed close
handshake.

``WebSocket/Options`` stores configurable send capacities and policies. Defaults are 16 outstanding
messages and 1 MiB of payload, serialization, and preservation when a failed send has not started
writing. The capacities count active and queued sends together. These values do not implement a
queue or validate a connection. Receive limits and operation deadlines are not configured yet.

```swift
let message = WebSocket.Message.text("hello")
let options = WebSocket.Options(
  maxPendingSendBytes: 2_097_152,
  maxPendingSendMessages: 32,
  sendFailurePolicy: .abortConnection
)
```

``WebSocketRequest`` stores a URL, headers, subprotocol preferences and an optional `Authentication`
value without invoking credentials. ``WebSocketError`` retains actual response and close metadata
when supplied; absent response metadata remains nil. Its description omits peer reasons, underlying
error descriptions and arbitrary custom kind strings. Raw diagnostic properties may contain secrets.

The `HTTPTesting` product provides `MockWebSocketTransport`, `ScriptedWebSocketConnection` and
`WebSocketRendezvous`. Scripts return seeded outcomes and record calls without implementing retry,
authentication, queue or lifecycle policy. Their cancellation-safe gates coordinate test operations,
not live socket behavior.

## Topics

### Messages and Configuration

- ``WebSocket``
- ``WebSocket/Message``
- ``WebSocket/Options``
- ``WebSocket/SendFailurePolicy``
- ``WebSocket/SendPolicy``

### Handshake Inputs and Diagnostics

- ``WebSocketRequest``
- ``WebSocketClose``
- ``WebSocket/CloseCode``
- ``WebSocketError``
