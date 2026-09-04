// `StreamingExchange` exists only behind the `HTTPPortable` trait, so this suite compiles away
// without it.
#if HTTPPortable

import AsyncHTTPClient
import Foundation
import HTTPCore
import HTTPPortable
import HTTPTesting
import HTTPTypes
import NIOCore
import Synchronization
import Testing

/// A client body a test feeds by hand. It decides nothing: it hands out what it was given, in
/// order, ends how it was told to end, and records each pull as it is made.
private final class Feed: Sendable {
  private struct Chunks: AsyncSequence, Sendable {
    typealias Element = ByteBuffer
    typealias Failure = any Error

    struct AsyncIterator: AsyncIteratorProtocol {
      var base: AsyncThrowingStream<ByteBuffer, any Error>.AsyncIterator
      let feed: Feed

      mutating func next(isolation actor: isolated (any Actor)?) async throws -> ByteBuffer? {
        feed.pulls.arrive()
        return try await base.next(isolation: actor)
      }
    }

    let feed: Feed

    func makeAsyncIterator() -> AsyncIterator {
      AsyncIterator(base: feed.stream.makeAsyncIterator(), feed: feed)
    }
  }

  private let continuation: AsyncThrowingStream<ByteBuffer, any Error>.Continuation
  private let stream: AsyncThrowingStream<ByteBuffer, any Error>

  /// Arrived at once per pull the exchange has made.
  let pulls = Latch()

  init() {
    (stream, continuation) = AsyncThrowingStream.makeStream()
  }

  /// The body, as the client would hand it to the exchange.
  var body: HTTPClientResponse.Body {
    .stream(Chunks(feed: self))
  }

  func yield(_ text: String) {
    continuation.yield(ByteBuffer(string: text))
  }

  func yield(count: Int) {
    continuation.yield(ByteBuffer(repeating: 0, count: count))
  }

  func finish(throwing error: (any Error)? = nil) {
    continuation.finish(throwing: error)
  }
}

/// Parks the calling task until it is cancelled: a read from a stream nothing writes to ends on
/// cancellation and on nothing else.
private func parkUntilCancelled() async {
  for await _ in AsyncStream<Never>(Never.self, { _ in }) {}
}

private let okHead = StreamingExchange.Head(headers: [:], status: .ok)

/// The buffered byte count above which the exchange stops pulling: the buffer's documented default,
/// 512 KiB. It pulls again at or below the documented 128 KiB, which an empty buffer is.
private let highWatermark = 512 * 1024

/// An exchange started over `feed`, delivering `okHead` and arriving at `ended` once its run has
/// returned or thrown.
private func startExchange(over feed: Feed, arrivingAt ended: Latch) -> StreamingExchange {
  let exchange = StreamingExchange()
  exchange.start {
    defer { ended.arrive() }
    try await exchange.deliver(head: okHead, body: feed.body)
  } failure: { error in
    AsyncHTTPClientTransport.failure(from: error)
  }
  return exchange
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct StreamingExchangeTests {
  @Test("A body delivered in three buffers arrives as three chunks in order")
  func aBodyDeliveredInThreeBuffersArrivesAsThreeChunksInOrder() async throws {
    let feed = Feed()
    let exchange = startExchange(over: feed, arrivingAt: Latch())
    for chunk in ["one", "two", "three"] {
      feed.yield(chunk)
    }
    feed.finish()

    #expect(try await exchange.response().status.code == 200)
    let (received, failure) = await drain(exchange.makeBody())
    #expect(received.map(text) == ["one", "two", "three"])
    #expect(failure == nil)
  }

  @Test(
    "A failure after the response arrives reaches the reader through the body, after its chunks")
  func aFailureAfterTheResponseReachesTheReaderThroughTheBody() async throws {
    let feed = Feed()
    let exchange = startExchange(over: feed, arrivingAt: Latch())
    feed.yield("partial")
    feed.finish(throwing: HTTPClientError.remoteConnectionClosed)

    #expect(try await exchange.response().status.code == 200)
    let (received, failure) = await drain(exchange.makeBody())
    #expect(received.map(text) == ["partial"])
    let error = try #require(failure)
    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .connectivity)
    #expect(underlying as? HTTPClientError == .remoteConnectionClosed)
  }

  @Test("A run that throws before delivering fails the response with the mapped failure")
  func aRunThatThrowsBeforeDeliveringFailsTheResponse() async throws {
    let exchange = StreamingExchange()
    exchange.start {
      throw HTTPClientError.connectTimeout
    } failure: { error in
      AsyncHTTPClientTransport.failure(from: error)
    }

    let error: TransportError
    do throws(TransportError) {
      _ = try await exchange.response()
      Issue.record("expected the response to fail")
      return
    } catch let caught {
      error = caught
    }
    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .timedOut)
    #expect(underlying as? HTTPClientError == .connectTimeout)
  }

  @Test("Cancelling the exchange while the request is in flight fails the response with cancelled")
  func cancellingTheExchangeWhileTheRequestIsInFlightFailsTheResponseWithCancelled() async throws {
    let started = Latch()
    let exchange = StreamingExchange()
    exchange.start {
      started.arrive()
      await parkUntilCancelled()
      try Task.checkCancellation()
    } failure: { error in
      AsyncHTTPClientTransport.failure(from: error)
    }
    await started.wait(forCount: 1)

    exchange.cancel()

    let error: TransportError
    do throws(TransportError) {
      _ = try await exchange.response()
      Issue.record("expected the response to fail")
      return
    } catch let caught {
      error = caught
    }
    #expect(isCancelled(error))
  }

  @Test("The exchange pulls again once the reader has drained the buffer past the watermark")
  func theExchangePullsAgainOnceTheReaderHasDrained() async throws {
    let feed = Feed()
    let exchange = startExchange(over: feed, arrivingAt: Latch())
    _ = try await exchange.response()
    var iterator = exchange.makeBody().makeAsyncIterator()

    // The first pull is made as soon as the head is delivered; one chunk past the high watermark
    // answers it, and the buffer suspends the exchange before it can pull again.
    await feed.pulls.wait(forCount: 1)
    feed.yield(count: highWatermark + 1)

    // Taking the chunk drains the buffer to nothing, which is at or below the low watermark, and
    // the second pull follows from that. That no second pull comes before the drain is the
    // buffer's suspend and the control's park, proven in `ChunkBufferTests` and `PumpControlTests`;
    // this test proves the resume reaches the pull.
    let first = try await iterator.next()
    #expect(first?.count == highWatermark + 1)
    await feed.pulls.wait(forCount: 2)

    feed.finish()
    let end = try await iterator.next()
    #expect(end == nil)
  }

  @Test("Dropping the body while the exchange is parked above the watermark ends the task")
  func droppingTheBodyWhileParkedAboveTheWatermarkEndsTheTask() async throws {
    let feed = Feed()
    let ended = Latch()
    let exchange = startExchange(over: feed, arrivingAt: ended)
    _ = try await exchange.response()
    let body = exchange.makeBody()
    await feed.pulls.wait(forCount: 1)
    feed.yield(count: highWatermark + 1)

    _ = consume body

    await ended.wait(forCount: 1)
  }

  @Test("Dropping the body while the exchange is waiting on the client ends the task")
  func droppingTheBodyWhileWaitingOnTheClientEndsTheTask() async throws {
    let feed = Feed()
    let ended = Latch()
    let exchange = startExchange(over: feed, arrivingAt: ended)
    _ = try await exchange.response()
    let body = exchange.makeBody()
    await feed.pulls.wait(forCount: 1)

    _ = consume body

    await ended.wait(forCount: 1)
  }

  @Test("A run that returns without delivering fails the response as other, so no caller parks")
  func aRunThatReturnsWithoutDeliveringFailsTheResponse() async throws {
    let exchange = StreamingExchange()
    exchange.start {
    } failure: { error in
      AsyncHTTPClientTransport.failure(from: error)
    }

    let error: TransportError
    do throws(TransportError) {
      _ = try await exchange.response()
      Issue.record("expected the response to fail")
      return
    } catch let caught {
      error = caught
    }
    let (kind, underlying) = try #require(transportFailure(error))
    #expect(kind == .other)
    #expect(underlying == nil)
  }

  @Test("A response settled before the call is returned at once")
  func aResponseAlreadySettledIsReturnedAtOnce() async throws {
    let feed = Feed()
    let ended = Latch()
    let exchange = startExchange(over: feed, arrivingAt: ended)
    feed.finish()
    await ended.wait(forCount: 1)

    #expect(try await exchange.response().status.code == 200)
    let (received, failure) = await drain(exchange.makeBody())
    #expect(received.isEmpty)
    #expect(failure == nil)
  }
}

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct PumpControlTests {
  @Test("A task parked by suspend passes once resume is called")
  func aTaskParkedBySuspendPassesOnceResumeIsCalled() async throws {
    let control = PumpControl()
    let entered = Latch()
    let passed = Latch()
    control.suspend()
    let waiting = Task {
      entered.arrive()
      await control.waitWhileSuspended()
      passed.arrive()
    }
    await entered.wait(forCount: 1)

    control.resume()

    await passed.wait(forCount: 1)
    await waiting.value
  }

  @Test("A task parked by suspend passes once cancel is called, and the attached task is cancelled")
  func aTaskParkedBySuspendPassesOnceCancelIsCalled() async throws {
    let control = PumpControl()
    let entered = Latch()
    let cancelled = Latch()
    control.suspend()
    let waiting = Task {
      entered.arrive()
      await control.waitWhileSuspended()
      if Task.isCancelled { cancelled.arrive() }
    }
    control.attach(waiting)
    await entered.wait(forCount: 1)

    control.cancel()

    await cancelled.wait(forCount: 1)
    await waiting.value
  }

  @Test("A task attached after cancel is cancelled at once rather than held")
  func aTaskAttachedAfterCancelIsCancelledAtOnce() async throws {
    let control = PumpControl()
    let cancelled = Latch()
    control.cancel()

    let late = Task {
      await parkUntilCancelled()
      if Task.isCancelled { cancelled.arrive() }
    }
    control.attach(late)

    await cancelled.wait(forCount: 1)
    await late.value
  }

  @Test("A wait while delivery is running returns at once")
  func aWaitWhileRunningReturnsAtOnce() async {
    let control = PumpControl()

    await control.waitWhileSuspended()
    control.suspend()
    control.resume()
    await control.waitWhileSuspended()
  }
}

#endif
