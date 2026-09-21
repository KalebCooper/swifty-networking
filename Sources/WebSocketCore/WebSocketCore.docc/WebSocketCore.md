# ``WebSocketCore``

Own a WebSocket connection through an injected backend, with bounded receiving and explicit cleanup.

## Overview

``WebSocketClient`` opens a ``WebSocket`` using a ``WebSocketTransport``. The client accepts
a request or URL, defaults to ContinuousClock, and supports an injected clock. Network adapters
are not yet implemented or qualified. Application sending and caller-initiated graceful close
are not yet exposed on the shared handle.

Opening validates options and requests before credential or backend work. Authentication retains
the same refresh identity as HTTP. One configurable connectTimeout, thirty seconds by default,
covers credentials, refresh waiting and both attempts. Only an actual pre-upgrade HTTP 401 can
trigger one eligible replay. Backends must refuse redirects and preserve actual response metadata.
Cancellation releases the caller without abandoning shared credential rotation, and late
successful connections are aborted.

### Ownership and Receiving

The socket, its ``WebSocketMessages`` value and its iterators retain the connection.
Releasing the last external owner aborts it, even with a receive or ping pending.
Creating another messages value or iterator does not start another receive pump.
The result-returning withConnection conveniences abort on normal exit, error and cancellation;
their operation and result may remain isolated to the caller and need not be Sendable.
An escaped handle is terminal after scope exit.

The first next() claims the reader. Copies share that claim and permit only one pending next().
A competing reader or overlapping call throws concurrentOperation without disturbing the owner.
Cancellation finishes the iterator and releases its pending read without cancelling the physical
receive. A new iterator can consume unread messages. Releasing the last iterator copy releases
its claim without closing a separately retained socket. Cancellation and delivery race for
settlement: a delivery that wins returns its message, avoiding silent loss.

Receive defaults are 1 MiB per message, 1 MiB of buffered payload and 16 buffered messages.
Empty messages count toward the message capacity. Text counts UTF-8 bytes. Limits must be
positive, and byte capacities must accommodate maxMessageBytes. Capacity checks avoid integer
overflow. These bounds cover the completed-message inbox plus one message being received and
bookkeeping overhead; backend buffers and copies remain outside this accounting.

Overflow fails the connection with bufferOverflow; an oversized message reports messageTooLarge.
Buffered payloads are released on failure. The core attempts a bounded close with code 1008
or 1009 respectively, then aborts the backend. closeTimeout defaults to five seconds.
A valid peer close drains already buffered messages before ending the sequence.
``WebSocketClose`` preserves an absent code and raw application-defined codes.

### Ping and Cancellation

Only one ping probe may be outstanding. Cancellation before admission sends nothing.
After admission, cancellation releases the caller while the physical probe and its original
deadline continue. A matching pong frees the slot. The configurable pingTimeout defaults to
ten seconds; expiry terminates the connection with timedOut, including after caller cancellation.
Overlapping pings throw concurrentOperation. There is no automatic heartbeat or reconnect.

### Backend and Test Contracts

``WebSocketConnection`` supplies complete-message receive, pong completion, close and synchronous
idempotent abort. Its operations must cooperate with abort and release resources promptly.
A normal receive end requires peer close metadata to be available already; an absent close is a
protocol failure. Backends must support receive and controls concurrently. Conformance requires
live qualification beyond the scripted shared-core tests.

HTTPTesting supplies MockWebSocketTransport, ScriptedWebSocketConnection and WebSocketRendezvous.
Scripts record calls and return seeded outcomes; they do not implement lifecycle policy.
Synchronous cancel records an abort without consuming an asynchronous step. The remaining
operations consume the same explicit FIFO; tests use gates to establish ordering.

``WebSocket/Options`` also retains send capacities and policies for the forthcoming send surface.
Those configuration values do not currently implement an application send queue.
``WebSocketError`` descriptions omit arbitrary diagnostic strings, while raw response, close and
underlying-error properties may contain sensitive information.

## Topics

### Connections and Ownership

- ``WebSocketClient``
- ``WebSocket``
- ``WebSocketMessages``
- ``WebSocketConnection``
- ``WebSocketTransport``

### Messages and Configuration

- ``WebSocket/Message``
- ``WebSocket/Options``
- ``WebSocket/SendFailurePolicy``
- ``WebSocket/SendPolicy``

### Handshake Inputs and Diagnostics

- ``WebSocketRequest``
- ``WebSocketClose``
- ``WebSocket/CloseCode``
- ``WebSocketError``
