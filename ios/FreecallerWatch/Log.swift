import Foundation
import os

/// Logging that can be read on the watch itself. The family's watches are not
/// on a desk next to a Mac with Console open, so the last few hundred lines are
/// kept in memory and shown on the Diagnostics screen.
enum Log {
  private static let logger = Logger(subsystem: "com.unnanego.freecaller.watch", category: "app")
  private static let lock = NSLock()
  private static var ring: [String] = []
  /// Lines not yet sent to the server (CallController.flushLog). Bounded like
  /// the ring, so a watch that never gets to send cannot grow it forever.
  private static var unsent: [String] = []
  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  static func info(_ message: String) {
    logger.info("\(message, privacy: .public)")
    append(message)
  }

  static func error(_ message: String, _ error: Error? = nil) {
    let line = error.map { "\(message): \($0)" } ?? message
    logger.error("\(line, privacy: .public)")
    append("⚠️ " + line)
  }

  static func recent() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return ring.reversed()
  }

  /// Takes up to `maxChars` of the oldest unsent lines, oldest first. Lines
  /// that fail to send are handed back with `putBack`.
  static func takeUnsent(maxChars: Int) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    var taken: [String] = []
    var size = 0
    while let first = unsent.first, size + first.count + 1 <= maxChars || taken.isEmpty {
      taken.append(String(first.prefix(maxChars)))
      size += first.count + 1
      unsent.removeFirst()
    }
    return taken
  }

  static func putBack(_ lines: [String]) {
    lock.lock()
    defer { lock.unlock() }
    unsent.insert(contentsOf: lines, at: 0)
    if unsent.count > 300 { unsent.removeFirst(unsent.count - 300) }
  }

  private static func append(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    let line = "\(formatter.string(from: Date())) \(message)"
    ring.append(line)
    if ring.count > 300 { ring.removeFirst(ring.count - 300) }
    unsent.append(line)
    if unsent.count > 300 { unsent.removeFirst(unsent.count - 300) }
  }
}
