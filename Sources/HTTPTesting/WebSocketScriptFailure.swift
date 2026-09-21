/// An error in the supplied WebSocket test script.
public enum WebSocketScriptFailure: Error, Equatable, Sendable {
  /// A recorded call had no seeded outcome.
  case noScriptedOutcome
}
