#if WebSocketPortable
import NIOCore
import WebSocketCore

/// Writes a frame header and half its payload, then holds its completion until channel closure.
final class PartialWriteHandler: ChannelOutboundHandler, RemovableChannelHandler {
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private var held: EventLoopPromise<Void>?
  private var writes = 0

  func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
    held?.fail(ChannelError.ioOnClosedChannel)
    held = nil
    context.close(mode: mode, promise: promise)
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    held?.fail(ChannelError.ioOnClosedChannel)
    held = nil
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    writes += 1
    if writes == 2 {
      var payload = unwrapOutboundIn(data)
      let prefix = payload.readSlice(length: payload.readableBytes / 2) ?? ByteBuffer()
      held = promise
      context.writeAndFlush(wrapOutboundOut(prefix), promise: nil)
    } else {
      context.write(data, promise: promise)
    }
  }
}
#endif
