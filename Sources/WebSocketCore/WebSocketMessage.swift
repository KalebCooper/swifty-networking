#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension WebSocket {
  /// One complete application message.
  public enum Message: Equatable, Sendable {
    /// Binary data, including an empty payload.
    case binary(Data)

    /// Text, including an empty string.
    case text(String)

    /// The payload size in bytes, using UTF-8 for text.
    public var byteCount: Int {
      switch self {
      case .binary(let data): data.count
      case .text(let text): text.utf8.count
      }
    }
  }
}
