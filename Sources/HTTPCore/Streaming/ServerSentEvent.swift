/// One event dispatched by a `text/event-stream`.
///
/// An event is what a blank line closes: the fields gathered since the last blank line, read as the
/// event-stream grammar defines them. A frame that carried no `data` field dispatches no event, so
/// every value of this type has data, possibly the empty string, which is what `data:` with nothing
/// after it means.
///
/// ```swift
/// for try await event in SSEDecoder(LineSplitter(bytes)) {
///   switch event.event {
///   case "message": append(event.data)
///   case "done": return
///   default: break
///   }
/// }
/// ```
///
/// ## Event State and Stream State
///
/// ``data`` and ``event`` are the frame's own. ``id`` and ``retry`` belong to the stream, and are
/// reported here as the values in force when this event was dispatched: the grammar keeps a last
/// event id and a reconnection time across frames, and a frame may set either without dispatching
/// anything. An id may therefore repeat across several events, and reading one reads what the
/// stream last said. Carrying them any other way would lose them, since a frame of nothing but
/// `retry: 3000` dispatches no event to hang the value on.
///
/// ``SSEDecoder`` reports both and acts on neither. ``EventSource`` acts on both: it carries the id
/// on each reconnect and waits the reconnection time before one.
public struct ServerSentEvent: Equatable, Hashable, Sendable {
  /// The event's data, with the lines of a multi-line `data` field joined by a line feed.
  ///
  /// Empty when the frame's `data` fields were all empty. That is a dispatched event carrying
  /// nothing, which is not the same as no event.
  public let data: String

  /// The event's type, which is `message` when the frame named none.
  ///
  /// The default is the grammar's own: a frame with no `event` field dispatches an event of type
  /// `message`, and a server and a client cannot tell the two apart, so there is nothing for an
  /// optional to say.
  public let event: String

  /// The stream's last event id when this event was dispatched, or `nil` when it has none.
  ///
  /// An `id` field sets it, and it is kept until another one replaces it, so consecutive events may
  /// report the same id and an event whose own frame carried no `id` still reports the last one
  /// seen. An `id` field with an empty value clears it, and is reported here as `nil`.
  public let id: String?

  /// The reconnection time the stream last asked for, or `nil` when it has asked for none.
  ///
  /// The server sends a whole number of milliseconds, and this property reports it as a `Duration`.
  /// It is kept across frames like ``id``. ``SSEDecoder`` does not act on it; ``EventSource``
  /// waits it before each reconnect.
  public let retry: Duration?

  /// Creates an event.
  ///
  /// - Parameters:
  ///   - data: The event's data.
  ///   - event: The event's type; defaults to the grammar's own `message`.
  ///   - id: The stream's last event id, or `nil` when it has none.
  ///   - retry: The reconnection time the stream asked for, or `nil` when it has asked for none.
  public init(data: String, event: String = "message", id: String? = nil, retry: Duration? = nil) {
    self.data = data
    self.event = event
    self.id = id
    self.retry = retry
  }
}
