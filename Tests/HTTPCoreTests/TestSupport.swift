import HTTPCore
import HTTPTesting
import HTTPTypes
import Synchronization
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A ``FlowControl`` that records every call in the order it was made and decides nothing.
///
/// A test target cannot import another's, so this lives here beside `failure(of:)` for every suite
/// that puts a `ChunkBuffer` behind something.
final class CountingControl: FlowControl {
  /// One call a buffer made on its control.
  enum Call: Equatable {
    case cancel
    case resume
    case suspend
  }

  private struct State {
    var calls: [Call] = []
    var waiters: [(call: Call, continuation: CheckedContinuation<Void, Never>)] = []
  }

  private let state = Mutex(State())

  var calls: [Call] {
    state.withLock { $0.calls }
  }

  func cancel() {
    record(.cancel)
  }

  func resume() {
    record(.resume)
  }

  func suspend() {
    record(.suspend)
  }

  /// Waits for the buffer to make `call`, returning at once when it already has.
  ///
  /// A waiter is resumed inside the same critical section that records the call, so a resume is
  /// never left owing and a test waits on the buffer's own progress rather than polling for it.
  func wait(for call: Call) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumeNow = state.withLock { state -> Bool in
        guard !state.calls.contains(call) else { return true }
        state.waiters.append((call: call, continuation: continuation))
        return false
      }
      if resumeNow {
        continuation.resume()
      }
    }
  }

  private func record(_ call: Call) {
    let due = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.calls.append(call)
      let ready = state.waiters.filter { $0.call == call }
      state.waiters.removeAll { $0.call == call }
      return ready.map(\.continuation)
    }
    for continuation in due {
      continuation.resume()
    }
  }
}

/// Runs `body` and returns the typed failure it threw, or `nil` when it succeeded.
///
/// The closure is untyped on purpose. Declaring it `throws(TransportError)` would make the
/// compiler enforce what these tests exist to observe, so a call that threw something else would
/// stop compiling instead of failing; untyped, the wrong error type is recorded as an issue naming
/// what actually arrived.
///
/// A test target cannot import another's, so this lives once per target beside `URL.fixture`.
func failure<Value>(
  of body: () async throws -> Value,
  sourceLocation: SourceLocation = #_sourceLocation
) async -> TransportError? {
  do {
    _ = try await body()
    return nil
  } catch let error as TransportError {
    return error
  } catch {
    Issue.record("expected a TransportError, got \(error)", sourceLocation: sourceLocation)
    return nil
  }
}

/// Awaits and advances `count` sleeps on `clock`, one deadline group at a time.
///
/// Await-then-advance, so a test never polls and never sleeps on the wall clock. Awaiting first is
/// also what makes a missing wait visible: a wait that never arrives hangs here, and a hang past
/// the suite's ceiling is a failure, where advancing an empty clock would have skipped silently
/// and passed.
func answerWaits(_ count: Int, of clock: RecordingClock) async {
  for _ in 0..<count {
    await clock.waitForPendingSleep()
    clock.advanceAll()
  }
}

/// The `Authorization` values the transport saw, in send order; `nil` where a request carried none.
func authorizations(of transport: MockTransport) -> [String?] {
  transport.requests.map { $0.request.headerFields[.authorization] }
}

/// The `:path` of every request the transport saw, in send order.
func paths(of transport: MockTransport) -> [String?] {
  transport.requests.map { $0.request.path }
}

/// Whether the failure is a transport failure of kind `badURL`.
func isBadURL(_ error: TransportError?) -> Bool {
  if case .some(.transport(kind: .badURL, underlying: _)) = error { true } else { false }
}

/// The status code of a status failure.
func statusCode(_ error: TransportError?) -> Int? {
  if case .some(.httpStatus(body: _, code: let code, headers: _)) = error { code } else { nil }
}

/// A redirect carrying `location`, with a body a follower must never read.
func redirect(_ code: Int, to location: String?) -> Response {
  var headers: HTTPFields = [:]
  if let location { headers[.location] = location }
  return Response(
    body: Data("<html>moved</html>".utf8), headers: headers, status: HTTPResponse.Status(code: code)
  )
}
