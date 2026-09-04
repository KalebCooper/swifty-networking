import HTTPTypes

/// A sequence of server-sent events that reconnects when the stream ends or fails, re-issuing the
/// request with `Last-Event-ID`.
///
/// ``HTTPClient/stream(_:)`` sends once, and ``SSEDecoder`` reads one body. A `text/event-stream`
/// is meant to outlive any one connection: the server closes it, the network drops it, and the
/// client is expected to come back with the last event id it saw so the server can resume. This
/// type is that client. It opens the stream through
/// ``HTTPClient/events(_:maxLineLength:reconnectDelay:)``'s client, reads it as an ``SSEDecoder``
/// does, and when the body ends or fails with a transport failure, waits and opens it again with the
/// `Last-Event-ID` field set to the last id the server sent.
///
/// ```swift
/// for try await event in client.events(Request(path: "/events")) {
///   handle(event)
/// }
/// ```
///
/// The sequence follows the WHATWG `EventSource` rules for when to come back and when to stop. It
/// reconnects after a clean end and after ``TransportError/transport(kind:underlying:)``, whether
/// the failure happened while connecting or part-way through the body, and it keeps reconnecting
/// for as long as the consumer reads: there is no attempt limit, and cancelling the reading task is
/// how the sequence ends. It stops on a status outside `2xx`, thrown as
/// ``TransportError/httpStatus(body:code:headers:)``, because the server refused the request and
/// would refuse it again; on a `204`, cleanly, because that is the status a server sends to say
/// there is nothing more to subscribe to; on ``TransportError/decode(underlying:)``, because a
/// stream that is not UTF-8 would be as broken on the next connection; and on a line past
/// ``maxLineLength``, which arrives as a transport failure carrying ``LineSplitterFailure`` and is
/// a limit you set rather than a network fault. The response's `Content-Type` is not checked.
///
/// ## Timing a Reconnect
///
/// The wait before each reconnect is the last `retry` field the server sent, on ``client``'s
/// ``HTTPClient/clock``, and ``reconnectDelay`` until it has sent one. Both the reconnection time and
/// the last event id are read from the stream as the grammar keeps them, so a frame carrying only
/// an `id` or a `retry` field and no data still counts, and an `id` field with an empty value
/// clears the id so the next reconnect carries none. Each connection is a
/// ``HTTPClient/stream(_:)`` call, so it keeps the resolution, the credential rules, and the
/// redirect rules, and a failed attempt that answers with a status outside `2xx` reads up to 64 KiB
/// of that body with no deadline over it before the failure is thrown. See <doc:Streaming>.
///
/// ```swift
/// let events = client.events(Request(path: "/events"), reconnectDelay: .seconds(1))
/// ```
///
/// ## Cancellation
///
/// A consumer whose task is cancelled sees ``TransportError/cancelled`` from its next read at the
/// latest, whether it was parked on a body, waiting to reconnect, or between the two, and the
/// sequence never reconnects on a cancelled task. Once a read has thrown or returned `nil`, the
/// iterator is finished and every later read returns `nil`. See <doc:Streaming>.
///
/// ```swift
/// let reading = Task {
///   for try await event in client.events(Request(path: "/events")) { handle(event) }
/// }
///
/// reading.cancel()  // The next read throws TransportError.cancelled.
/// ```
public struct EventSource: AsyncSequence, Sendable {
  /// One dispatched event.
  public typealias Element = ServerSentEvent
  /// The only error a read can throw.
  public typealias Failure = TransportError

  /// The client each connection is opened through, whose clock times the waits between them.
  public let client: HTTPClient

  /// The most bytes a single line may carry, or `nil` for no limit, handed to the ``SSEDecoder``
  /// each connection is read through.
  public let maxLineLength: Int?

  /// The wait before a reconnect until the server has sent a `retry` field.
  public let reconnectDelay: Duration

  /// The request each connection sends, with `Last-Event-ID` added once an id has been seen.
  public let request: Request

  /// Creates a sequence that opens `request` through `client` and reopens it when the stream ends.
  ///
  /// - Parameters:
  ///   - client: The client each connection is opened through.
  ///   - maxLineLength: The most bytes a single line may carry, or `nil` for no limit.
  ///   - reconnectDelay: The wait before a reconnect until the server has sent a `retry` field;
  ///     three seconds by default, which is what browsers wait.
  ///   - request: The request each connection sends.
  public init(
    client: HTTPClient,
    maxLineLength: Int? = nil,
    reconnectDelay: Duration = .seconds(3),
    request: Request
  ) {
    self.client = client
    self.maxLineLength = maxLineLength
    self.reconnectDelay = reconnectDelay
    self.request = request
  }

  /// An iterator that opens the first connection on its first read.
  public func makeAsyncIterator() -> Iterator {
    Iterator(self)
  }

  /// The iterator over an ``EventSource``.
  ///
  /// It is not `Sendable`: it holds the decoder's iterator over the current connection's body,
  /// which is in exclusive use by whichever task is reading it, along with the last event id and
  /// the reconnection time that outlive each connection.
  public struct Iterator: AsyncIteratorProtocol {
    /// One dispatched event.
    public typealias Element = ServerSentEvent
    /// The only error `next()` can throw.
    public typealias Failure = TransportError

    /// Whether a connection has been opened, so that every connection but the first waits first.
    private var connected = false
    /// The wait before the next reconnect: the server's last `retry`, or the sequence's default.
    private var delay: Duration
    /// The decoder over the current connection's body, or `nil` between connections.
    private var events: SSEDecoder<StreamedBody>.Iterator?
    /// Whether the sequence has ended, after which every read returns `nil`.
    private var finished = false
    /// The last event id the server sent, carried on each reconnect, or `nil` when it has sent
    /// none or cleared it.
    private var lastEventID: String?
    /// The sequence being iterated.
    private let source: EventSource

    init(_ source: EventSource) {
      delay = source.reconnectDelay
      self.source = source
    }

    /// The next event, from the current connection or the next one.
    ///
    /// - Throws: ``TransportError/cancelled`` when the reading task is cancelled;
    ///   ``TransportError/httpStatus(body:code:headers:)`` for a status outside `2xx`;
    ///   ``TransportError/decode(underlying:)`` for a line that is not valid UTF-8;
    ///   ``TransportError/transport(kind:underlying:)`` carrying ``LineSplitterFailure`` for a line
    ///   past the limit; and ``TransportError/encode(underlying:)`` when the request's body fails
    ///   to encode, which every connect would. Every other transport failure reconnects instead of
    ///   throwing.
    public mutating func next(
      isolation actor: isolated (any Actor)? = #isolation
    ) async throws(TransportError) -> ServerSentEvent? {
      while !finished {
        guard var events else {
          try await connect(isolation: actor)
          continue
        }

        let event: ServerSentEvent?
        do throws(TransportError) {
          event = try await events.next(isolation: actor)
        } catch {
          // The connection is over either way, and the stream state it gathered is what the
          // reconnect carries, whether or not an event ever reported it.
          self.events = nil
          remember(events)
          try settle(error)
          continue
        }

        guard let event else {
          self.events = nil
          remember(events)
          continue
        }
        self.events = events
        return event
      }
      return nil
    }

    /// Opens the next connection, waiting first unless it is the first one.
    ///
    /// A connect that fails is settled like a body failure: a transport failure leaves the
    /// iterator ready to connect again, and anything else finishes it.
    private mutating func connect(isolation actor: isolated (any Actor)?)
      async throws(TransportError)
    {
      if connected {
        do throws(TransportError) {
          try await source.client.wait(delay)
        } catch {
          finished = true
          throw error
        }
      }
      connected = true

      var request = source.request
      if let lastEventID, let lastEventIDField {
        request.headers[lastEventIDField] = lastEventID
      }

      let response: StreamedResponse
      do throws(TransportError) {
        response = try await source.client.openStream(request)
      } catch {
        try settle(error)
        return
      }

      // A server that has nothing more to send says so with a 204, which the grammar names as the
      // one status that ends a subscription without a failure.
      guard response.status != .noContent else {
        finished = true
        return
      }
      // The id outlives the connection that set it, so the new stream starts from it and an event
      // arriving before the server sends another still reports the id in force.
      var decoder = SSEDecoder(response.body, maxLineLength: source.maxLineLength)
        .makeAsyncIterator()
      decoder.lastEventID = lastEventID
      events = decoder
    }

    /// Keeps the stream state a connection gathered: its last event id, when it set one, and its
    /// reconnection time, when it sent one.
    ///
    /// A connection that set no id leaves the previous one in force, which is what lets the id
    /// survive a connection that dropped before saying anything, and an empty id clears it.
    private mutating func remember(_ events: SSEDecoder<StreamedBody>.Iterator) {
      if let identifier = events.lastEventID {
        lastEventID = identifier.isEmpty ? nil : identifier
      }
      if let reconnectionTime = events.reconnectionTime {
        delay = reconnectionTime
      }
    }

    /// Decides what a failure means: a return to reconnect, or a throw that ends the sequence.
    ///
    /// Cancellation is read from the task and not from the failure, so that no failure a transport
    /// reports on a cancelled task, whatever it says, is ever answered with a reconnect.
    private mutating func settle(_ failure: TransportError) throws(TransportError) {
      guard !Task.isCancelled else {
        finished = true
        throw .cancelled
      }
      if case .transport(_, let underlying) = failure, !(underlying is LineSplitterFailure) {
        return
      }
      finished = true
      throw failure
    }
  }
}

/// The header field a reconnect carries the last event id in.
///
/// `HTTPField.Name.init(_:)` is failable because it refuses a character a field name cannot carry,
/// and this name has none; it is optional here only because the initializer is.
private let lastEventIDField = HTTPField.Name("Last-Event-ID")
