import Foundation

/// Reorders downlink packets by sequence number and paces them out one per
/// playout slot.
///
/// Audio crosses TCP here (the WebSocket), so packets arrive late in bursts
/// rather than out of order. On the watch the bursts are big: its Wi-Fi radio
/// naps between wake-ups, and 10–20 packets (200–400 ms) can land at once. A
/// fixed three-slot buffer that skipped ahead past ten made that choppy —
/// every burst overflowed, all but three packets were thrown away, the three
/// played, and the buffer ran dry until the next burst (build 25: 2186 in,
/// 1314 played, nothing "lost").
///
/// Build 25 with a 300-ms ceiling still broke up: through the iPhone's
/// Bluetooth link the watch stalls for ~1 s every few seconds, then 40+
/// packets land together, overflowed the 40-slot cap, and ~0.6 s was thrown
/// away at a time.
///
/// So the depth adapts. It starts at `minTarget` slots. When it runs dry and
/// then `burstPackets` or more arrive within `burstWindow` of each other, that
/// was a stall, not a pause in speech (after a pause packets come back one per
/// 20 ms), and it grows to hold a burst that size, up to `maxTarget` (1 s);
/// after `calmPeriod` seconds without such an underrun it shrinks by one. Only when the backlog passes
/// `target + catchUpSlack` does it start catching up, and then it skips
/// only near-silent packets (pauses between words encode tiny), which nobody
/// hears, while the player speeds up whenever `isBehind` (Speedup). Speech is
/// thrown away only past `maxDepth` (2 s) — a glitch is
/// better than delay that keeps growing.
///
/// Silence costs nothing: LiveKit's senders use DTX, so in a pause packets
/// stop coming while the sequence numbers stay contiguous. The buffer runs dry,
/// plays silence, and waits for `target` new packets before resuming.
///
/// Not thread-safe; AudioPipeline only touches it from its own queue.
final class JitterBuffer {
  enum Slot {
    case packet(Data)
    case lost  // a gap in the sequence: conceal it
    case empty  // nothing to play: silence
  }

  private let minTarget: Int
  private let maxTarget: Int
  private let maxDepth: Int
  private let catchUpSlack: Int
  private let quietBytes: Int
  private let burstPackets: Int
  private let burstWindow: TimeInterval
  private let calmPeriod: TimeInterval

  /// Current depth, in 20-ms slots, the buffer fills to before playing.
  private(set) var target: Int
  /// Packets thrown away: arrived after their slot played, or skipped on overflow.
  private(set) var dropped = 0
  /// Times the buffer ran dry mid-speech and grew.
  private(set) var underruns = 0

  /// Packets waiting to play.
  var backlog: Int { packets.count }
  /// More queued than the target: the player should speed up (Speedup).
  var isBehind: Bool { playing && packets.count > target + 2 }

  private var packets: [UInt16: Data] = [:]
  private var nextSeq: UInt16?
  private var playing = false
  private var dry = false
  private var refillStart: TimeInterval?
  private var refillCount = 0
  private var refillCounted = false
  private var lastChange: TimeInterval

  init(
    minTarget: Int = 3, maxTarget: Int = 50, maxDepth: Int = 100,
    catchUpSlack: Int = 10, quietBytes: Int = 20,
    burstPackets: Int = 5, burstWindow: TimeInterval = 0.05, calmPeriod: TimeInterval = 10,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    self.minTarget = minTarget
    self.maxTarget = maxTarget
    self.maxDepth = maxDepth
    self.catchUpSlack = catchUpSlack
    self.quietBytes = quietBytes
    self.burstPackets = burstPackets
    self.burstWindow = burstWindow
    self.calmPeriod = calmPeriod
    self.target = minTarget
    self.lastChange = now
  }

  func push(seq: UInt16, payload: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    if let next = nextSeq, playing, Self.isBefore(seq, next) {
      dropped += 1
      return  // its slot has already been played
    }
    if dry {
      // The first packet after running dry: watch whether a burst follows.
      dry = false
      refillStart = now
      refillCount = 0
      refillCounted = false
    }
    if let start = refillStart {
      if now - start <= burstWindow {
        refillCount += 1
        if refillCount >= burstPackets {
          // A stall mid-speech: hold the whole burst next time.
          let want = min(maxTarget, refillCount + 2)
          if want > target {
            target = want
            lastChange = now
          }
          if !refillCounted {
            refillCounted = true
            underruns += 1
          }
        }
      } else {
        refillStart = nil
      }
    }
    packets[seq] = payload
    if packets.count > maxDepth {
      // Hopelessly behind: drop the oldest, speech or not.
      let ordered = sortedKeys()
      let excess = packets.count - (target + catchUpSlack)
      for key in ordered.prefix(excess) { packets.removeValue(forKey: key) }
      dropped += excess
      nextSeq = sortedKeys().first
    }
  }

  func pop(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Slot {
    if target > minTarget, now - lastChange > calmPeriod {
      target -= 1
      lastChange = now
    }
    if !playing {
      guard packets.count >= target else { return .empty }
      playing = true
      nextSeq = sortedKeys().first
    }
    guard var next = nextSeq else { return .empty }
    // Behind: skip near-silent packets until back within the slack.
    while packets.count > target + catchUpSlack, let quiet = packets[next], quiet.count <= quietBytes {
      packets.removeValue(forKey: next)
      dropped += 1
      next = next &+ 1
    }
    nextSeq = next
    if let payload = packets.removeValue(forKey: next) {
      nextSeq = next &+ 1
      return .packet(payload)
    }
    if packets.isEmpty {
      playing = false  // dry (DTX pause or underrun): rebuffer
      dry = true
      return .empty
    }
    nextSeq = next &+ 1
    return .lost
  }

  func reset() {
    packets.removeAll()
    nextSeq = nil
    playing = false
    dry = false
    refillStart = nil
  }

  /// Sequence order with 16-bit wraparound.
  static func isBefore(_ a: UInt16, _ b: UInt16) -> Bool {
    Int16(bitPattern: a &- b) < 0
  }

  private func sortedKeys() -> [UInt16] {
    guard let any = packets.keys.first else { return [] }
    // Order relative to an arbitrary member, which is wrap-safe as long as the
    // spread is under half the sequence space — at most maxDepth here.
    return packets.keys.sorted { Int16(bitPattern: $0 &- any) < Int16(bitPattern: $1 &- any) }
  }
}
