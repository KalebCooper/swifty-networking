import HTTPCore
import Synchronization

/// A ``/HTTPCore/TransportObserver`` that keeps every event it receives, in the order the client
/// reported it.
///
/// Install one on an ``/HTTPCore/HTTPClient``, then read ``events`` once the request finishes: the
/// log shows what the client reported, not only what the request returned. Each event carries the
/// client's payload unchanged, so an assertion can read a status, an attempt ordinal, or the
/// correlation identifier that ties one logical request together.
///
/// ```swift
/// @Test func reportsTheSendAndTheResponse() async throws {
///   let observer = RecordingObserver()
///   let transport = MockTransport(results: [
///     .success(.ok(json: Fixtures.jsonObject(["id": "42"])))
///   ])
///   let client = HTTPClient(
///     baseURL: URL(string: "https://api.example.com")!,
///     observer: observer,
///     transport: transport
///   )
///
///   let response: Response = try await client.execute(Request(path: "/me"))
///
///   #expect(response.status == .ok)
///   #expect(observer.events.count == 2)
///   if case .received(let event) = observer.last {
///     #expect(event.status == .ok)
///     #expect(event.attempt == 1)
///   }
/// }
/// ```
///
/// Call ``reset()`` to return the observer to its freshly constructed state, with nothing recorded.
///
/// ## Isolation
///
/// One `Mutex` guards the log, so events reported from different tasks at the same moment are all
/// kept. The observer is not an `actor`, because every ``/HTTPCore/TransportObserver`` requirement
/// is synchronous and runs on whatever actor is executing the request.
public final class RecordingObserver: TransportObserver, Sendable {
  /// One event as this observer received it, carrying the payload the client reported unchanged.
  public enum Event: Sendable {
    /// A send ended in a failure.
    case failed(FailureEvent)

    /// A streamed body ended, cleanly or with a failure.
    case finishedBody(BodyEvent)

    /// A send produced a response, whatever its status.
    case received(ResponseEvent)

    /// A request is about to be sent.
    case sent(RequestEvent)
  }

  private struct State {
    var events: [Event] = []
  }

  private let limit: Int?
  private let state: Mutex<State>

  /// Creates an observer with nothing recorded yet.
  ///
  /// - Parameter bodyPreviewLimit: How many leading bytes of a body this observer receives; `nil`
  ///   by default, which receives none. Set it to drive
  ///   ``/HTTPCore/TransportObserver/bodyPreview(of:)`` through this instance the way a client
  ///   does.
  public init(bodyPreviewLimit: Int? = nil) {
    limit = bodyPreviewLimit
    state = Mutex(State())
  }

  /// How many leading bytes of a body this observer receives, as given to
  /// ``init(bodyPreviewLimit:)``.
  public var bodyPreviewLimit: Int? { limit }

  /// Every event captured so far, in the order it arrived.
  public var events: [Event] {
    state.withLock { $0.events }
  }

  /// The most recent event, or `nil` before any has been captured.
  public var last: Event? {
    state.withLock { $0.events.last }
  }

  /// Returns the observer to its freshly constructed state, with no events captured.
  public func reset() {
    state.withLock { $0 = State() }
  }

  /// Appends the failure to the log.
  ///
  /// - Parameter event: What failed, and how long the send took.
  public func didFail(_ event: FailureEvent) {
    state.withLock { $0.events.append(.failed(event)) }
  }

  /// Appends the end of the body to the log.
  ///
  /// - Parameter event: How many bytes were received, and what ended the body.
  public func didFinishBody(_ event: BodyEvent) {
    state.withLock { $0.events.append(.finishedBody(event)) }
  }

  /// Appends the response to the log.
  ///
  /// - Parameter event: The response's status, timing, and identifying detail.
  public func didReceive(_ event: ResponseEvent) {
    state.withLock { $0.events.append(.received(event)) }
  }

  /// Appends the request to the log.
  ///
  /// - Parameter event: What is about to go on the wire.
  public func willSend(_ event: RequestEvent) {
    state.withLock { $0.events.append(.sent(event)) }
  }
}
