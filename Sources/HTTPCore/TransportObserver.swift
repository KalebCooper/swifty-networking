// `Data` is the only Foundation type this file needs. The iOS SDK ships no separate
// FoundationEssentials module, so full Foundation is imported where that is the only option.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A type that receives a client's report of each send: one event before it, one after, and, for a
/// streamed body, one more when the body ends.
///
/// The unit is a send, not an attempt. A client that refreshes a credential and replays a rejected
/// request inside a single attempt makes two sends, and reports both, carrying the same
/// ``RequestEvent/attempt`` ordinal. Read the events in order to tell them apart.
///
/// Every requirement has a do-nothing default, so an observer that cares only about failures
/// implements ``didFail(_:)`` alone. Filtering is the observer's job: a client always reports every
/// send.
///
/// The package ships one conformer, `LoggingObserver`, behind the off-by-default `Logging` trait: it
/// writes every event to a swift-log `Logger` at a level of your choosing per kind.
///
/// ```swift
/// import HTTPCore
/// import Synchronization
///
/// final class FailureCounter: TransportObserver, Sendable {
///   private let failures = Atomic<Int>(0)
///
///   var count: Int { failures.load(ordering: .relaxed) }
///
///   func didFail(_ event: FailureEvent) {
///     failures.wrappingAdd(1, ordering: .relaxed)
///   }
/// }
/// ```
///
/// ## Conforming to the Protocol
///
/// - Keep the calls cheap. Each one runs inline on whatever actor is executing the request, before
///   the request continues, so format nothing expensive and block on nothing. Hand off work that
///   takes longer than a few microseconds.
/// - Do not call back into the client. An observer that issues a request from inside an event
///   recurses through the path that produced the event.
/// - Tolerate concurrency. One observer serves every request a client makes, so events from
///   unrelated requests can arrive at the same moment from different tasks. Keep state such as a
///   captured log or a counter in a `Mutex` or an `Atomic` inside a `struct` or a `final class`. A
///   conformer is never an `actor`, because the calls are synchronous.
///
/// ## What an Observer Receives
///
/// Events carry the request's shape and outcome: a method, the resolved target, a status, a
/// duration, an attempt number, a correlation identifier, and whether a credential was attached.
/// They never carry the credential itself and never carry a header field. A body reaches an
/// observer only when that observer asks for one through ``bodyPreviewLimit``, and then only up to
/// the byte count it named.
///
/// A streamed body is reported when it ends, through ``didFinishBody(_:)``, from the consumer's own
/// read. The event carries how many bytes the consumer received and the failure, if any, that
/// ended the body. A body dropped before it ended reports nothing.
///
/// Two events are not reported. A request that joins a coalesced flight never reaches the
/// transport, so it reports nothing, and the flight's own events are the record of the one
/// exchange. A decoding failure happens after the exchange, once per caller, so it reaches you as
/// ``TransportError/decode(underlying:)`` and goes nowhere else.
public protocol TransportObserver: Sendable {
  /// How many leading bytes of a body this observer receives; `nil`, the default, receives none.
  ///
  /// Bodies carry things that must not be recorded by accident, such as personal data or a token in
  /// a sign-in response, so the default is to see none of it. Name the budget you are willing to
  /// keep.
  var bodyPreviewLimit: Int? { get }

  /// Reports that one send ended in a failure.
  ///
  /// - Parameter event: What failed, and how long the send took.
  func didFail(_ event: FailureEvent)

  /// Reports that a streamed body ended, cleanly or with a failure.
  ///
  /// The call runs inline in the consumer's read that reached the end, once per body, so it
  /// arrives after every chunk delivered before it and never from a task the transport owns.
  ///
  /// - Parameter event: How many bytes were received, and what ended the body.
  func didFinishBody(_ event: BodyEvent)

  /// Reports that one send produced a response, whatever its status.
  ///
  /// - Parameter event: The response's status, timing, and identifying detail.
  func didReceive(_ event: ResponseEvent)

  /// Reports that a request is about to be sent.
  ///
  /// - Parameter event: What is about to go on the wire.
  func willSend(_ event: RequestEvent)
}

extension TransportObserver {
  /// Returns the leading bytes of a body that this observer's ``bodyPreviewLimit`` allows it to
  /// see.
  ///
  /// The client calls this method, so every event an observer receives is truncated by the same
  /// rule. A limit of `nil`, `0`, or a negative value all mean no preview.
  ///
  /// - Parameter body: The body to truncate.
  /// - Returns: The leading bytes of `body`, at most ``bodyPreviewLimit`` of them, or `nil` when
  ///   this observer receives no preview.
  public func bodyPreview(of body: Data) -> Data? {
    guard let limit = bodyPreviewLimit, limit > 0 else { return nil }
    return Data(body.prefix(limit))
  }

  /// Receives no body preview.
  public var bodyPreviewLimit: Int? { nil }

  /// Ignores the failure.
  ///
  /// - Parameter event: The unused event.
  public func didFail(_ event: FailureEvent) {}

  /// Ignores the end of the body.
  ///
  /// - Parameter event: The unused event.
  public func didFinishBody(_ event: BodyEvent) {}

  /// Ignores the response.
  ///
  /// - Parameter event: The unused event.
  public func didReceive(_ event: ResponseEvent) {}

  /// Ignores the request.
  ///
  /// - Parameter event: The unused event.
  public func willSend(_ event: RequestEvent) {}
}
