import Foundation

/// App-wide constants for the watch app. Values that also exist in the Flutter
/// app are mirrored from lib/core/config.dart and must stay in step with it.
enum Config {
  /// Self-hosted PocketBase — the same server the phones use.
  static let pbURL = URL(string: "https://pb.holographica.space")!

  /// deploy/watch-bridge, behind the same Caddy as PocketBase.
  static let bridgeURL = URL(string: "wss://pb.holographica.space/bridge/ws")!

  /// Loops audio straight back (BRIDGE_ECHO=1 on the server). Used by the
  /// echo test in Diagnostics — spike 1 in docs/watch-plan.md.
  static let echoURL = URL(string: "wss://pb.holographica.space/bridge/echo")!

  /// How long an outgoing call rings before the caller writes `missed`.
  /// Config.ringTimeout in the Flutter app; the server stamps the same 45s.
  static let ringTimeout: TimeInterval = 45

  /// How often a ringing incoming call re-reads its record, to notice the
  /// caller giving up or another of this user's devices answering.
  static let ringPollInterval: TimeInterval = 2

  /// How long a dropped bridge socket is retried before the call is given up.
  /// Shorter than the bridge's own seat grace (BRIDGE_DETACH_GRACE, 15s), so a
  /// reconnect that succeeds always finds the seat still held.
  static let reconnectWindow: TimeInterval = 12

  /// Ceiling on each server write made while ending a call
  /// (Config.teardownWriteTimeout in the Flutter app).
  static let teardownWriteTimeout: TimeInterval = 5

  /// The name CallKit shows for the app.
  static let appName = "Звонилка"
}
