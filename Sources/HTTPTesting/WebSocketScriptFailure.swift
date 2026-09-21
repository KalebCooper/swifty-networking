/// An error in the supplied WebSocket test script.
public enum WebSocketScriptFailure: Error, Equatable, Sendable {
  /// The seeded outcome did not match the operation's return type.
  case mismatchedOutcome

  /// A recorded call had no seeded outcome.
  case noScriptedOutcome
}
