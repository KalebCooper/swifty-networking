// `URLSession` and the loading system behind it exist only on Apple platforms, so this target
// compiles only where they do.
#if canImport(Darwin)

import Foundation

/// The delegate of a buffered `URLSession` task, there for one reason: to keep the loading system
/// from following a redirect.
///
/// `URLSession` follows a `3xx` on its own unless a task delegate says otherwise, and a transport
/// that let it would return the end of a chain nobody asked it to walk. ``URLSessionTransport``
/// gives every buffered call one of these, so a `3xx` comes back as the response it was, with its
/// `Location` field, for ``/HTTPCore/HTTPClient/redirectPolicy`` to act on.
/// ``StreamingTaskDelegate`` answers the same callback the same way on the streamed path.
///
/// ```swift
/// let (data, response) = try await session.data(for: request, delegate: RedirectRefusingDelegate())
/// ```
///
/// The delegate holds nothing, so one instance could serve every task; the transport makes one per
/// call because a task delegate is retained by its task and released with it.
package final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  /// Refuses the redirect, so the `3xx` is delivered as the task's response with its body.
  package func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

#endif
