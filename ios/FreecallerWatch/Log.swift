import Foundation
import os

/// Logging that can be read on the watch itself. The family's watches are not
/// on a desk next to a Mac with Console open, so the last few hundred lines are
/// kept in memory and shown on the Diagnostics screen.
enum Log {
  private static let logger = Logger(subsystem: "com.unnanego.freecaller.watch", category: "app")
  private static let lock = NSLock()
  private static var ring: [String] = []
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

  private static func append(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    ring.append("\(formatter.string(from: Date())) \(message)")
    if ring.count > 300 { ring.removeFirst(ring.count - 300) }
  }
}
