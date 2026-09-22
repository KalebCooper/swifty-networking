# ``WebSocketCore``

Own a WebSocket connection through an injected backend, with bounded receiving and sending, configurable policies and explicit cleanup.

## Overview

``WebSocketClient`` opens a ``WebSocket`` using a ``WebSocketTransport``. The client accepts
a request or URL, defaults to ContinuousClock, and supports an injected clock. WebSocketURLSession
provides the Apple adapter. WebSocketPortable supplies an opt-in NIO/NIOSSL client with explicit
transport shutdown. WebSocketHummingbird adapts accepted macOS and Linux server connections to
the same session behavior.

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
Buffered payloads are released on failure. When no data write or close frame is active, the core attempts a bounded close with code 1008
or 1009 respectively, then aborts the backend. Otherwise it aborts directly to avoid interleaving
frames. closeTimeout defaults to five seconds.
Backend-reported closure drains already buffered messages before ending the sequence.
``WebSocketClose`` preserves an absent code and raw application-defined codes.

### Sending and Completion

Async send and synchronous enqueue accept String, Data or ``WebSocket/Message`` through one
FIFO. Sequential enqueue calls establish admission order before returning. Concurrent producers
are ordered by admission, not by task creation. Each admitted message reaches one backend data
writer; receiving and ping may continue concurrently.

``WebSocket/Options`` defaults to 16 active-plus-queued sends and 1 MiB of pending payload.
Empty messages count; text counts UTF-8 bytes. Both limits are configurable above or below these
defaults, and maxPendingSendBytes must accommodate maxMessageBytes. Options are captured at connect.
Neither send nor enqueue waits for capacity: rejection is immediate, without hidden capacity waiters.
These limits bound retained send payloads and entries, not backend buffers, copies or result observers.

The connection's sendPolicy defaults to ``WebSocket/SendPolicy/serialize``.
``WebSocket/SendPolicy/rejectOverlapping`` rejects a send with concurrentOperation while another
is outstanding. Serialization admits behind it within capacity, otherwise throwing sendQueueFull.
An individual message over maxMessageBytes throws messageTooLarge.

The sendFailurePolicy defaults to ``WebSocket/SendFailurePolicy/preserveIfUnsent``: cancellation,
deadline expiry or rejection before writing fails only that operation and releases its capacity.
``WebSocket/SendFailurePolicy/abortConnection`` also aborts the session, preventing later dependent
messages from starting. Both policies abort once writing has started, because a partial message may
have reached the peer. Each send/enqueue can override either policy without changing the connection's
defaults or reordering surviving entries.

The configurable sendTimeout defaults to thirty seconds. Its single budget covers admission, queue
residence and the backend write; dequeue never starts a fresh budget. A queued cancellation or expiry
racing write start either removes the unstarted entry or aborts the connection if writing won.
Send attempts against a closing or terminal connection cannot restart it.

```swift
func sendUpdates(on socket: WebSocket) async throws {
  let first = try socket.enqueue("first")
  let second = try socket.enqueue("second", policy: .serialize)
  try await first.wait()
  try await second.wait()
  try await socket.send("last", failurePolicy: .abortConnection)
}
```

``WebSocket/SendOperation`` is an admitted send's shared result. Multiple callers can await it,
and later waits return the same result. Cancelling wait() detaches only that observer. Explicit
cancel() cancels the operation according to its failure policy; cancelling async send does the same
for its owned operation. Dropping a SendOperation does not cancel the send. Retaining one keeps
neither its payload after settlement nor the external socket ownership alive. Scope exit or release
of the last socket/message/iterator owner aborts outstanding work and settles escaped operations.

Completion means the backend finished writing. It neither acknowledges application receipt nor
guarantees remote execution. Failure does not prove that nothing reached the peer. Dependent commands
need application ordering and acknowledgements in addition to abortConnection; independent updates
can handle rejection or coalesce before admission. There is no automatic retry or reconnect.

### Graceful Close

close() atomically stops send admission and rejects queued sends with closed, regardless of those
sends' failure policies. It waits only for the active write before starting the close frame. Repeated
calls join the same attempt: the first valid code and reason win, with one closeTimeout including
the active-write wait. Invalid codes or reasons longer than 123 UTF-8 bytes throw invalidRequest
without altering the connection. Raw application codes 3000 through 4999 are accepted.
The returned ``WebSocketClose`` contains backend-reported closure metadata, including an absent code.
Success means the backend completed closing, not that the peer acknowledged a close frame.
URLSession may report the locally requested code and reason even when the peer replies differently
or does not send a close frame. These values must not be treated as application acknowledgements.

``WebSocket/CloseCancellationPolicy/stopWaiting`` is the per-call default: cancellation after
admission releases that caller while close continues under its original deadline.
``WebSocket/CloseCancellationPolicy/abortConnection`` aborts the connection and all joined callers
instead. Pre-cancellation starts nothing under either policy; cancellation cannot undo an already
completed close. A deadline or backend failure aborts and releases all waiters. Explicit cancel()
always aborts rather than awaiting a handshake.

### Ping and Cancellation

Only one ping probe may be outstanding. Cancellation before admission sends nothing.
After admission, cancellation releases the caller while the physical probe and its original
deadline continue. A matching pong frees the slot. The configurable pingTimeout defaults to
ten seconds; expiry terminates the connection with timedOut, including after caller cancellation.
Overlapping pings throw concurrentOperation. There is no automatic heartbeat or reconnect.

### Backend and Test Contracts

``WebSocketConnection`` supplies complete-message receive, pong completion, close and synchronous
idempotent abort. Its operations must cooperate with abort and release resources promptly.
A normal receive end requires backend closure metadata to be available already; an absent close is a
protocol failure. Backends must support receive and controls concurrently. Conformance requires
live qualification beyond the scripted shared-core tests.

HTTPTesting supplies MockWebSocketTransport, ScriptedWebSocketConnection and WebSocketRendezvous.
Scripts record calls and return seeded outcomes; they do not implement lifecycle policy.
Synchronous cancel records an abort without consuming an asynchronous step. The remaining
operations consume the same explicit FIFO; tests use gates to establish ordering.

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

- ``WebSocket/CloseCancellationPolicy``
- ``WebSocket/Message``
- ``WebSocket/Options``
- ``WebSocket/SendFailurePolicy``
- ``WebSocket/SendOperation``
- ``WebSocket/SendPolicy``

### Handshake Inputs and Diagnostics

- ``WebSocketRequest``
- ``WebSocketClose``
- ``WebSocket/CloseCode``
- ``WebSocketError``
