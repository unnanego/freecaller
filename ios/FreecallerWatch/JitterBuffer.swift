import Foundation

/// Reorders downlink packets by sequence number and paces them out one per
/// playout slot.
///
/// Small on purpose. Audio crosses TCP here (the WebSocket), so packets arrive
/// late in bursts rather than out of order, and every slot of buffer is 20 ms
/// more delay in a conversation. Three slots (60 ms) absorbs ordinary LTE
/// jitter; past ten (200 ms) the buffer skips ahead instead of letting the
/// delay grow — a short glitch is better than talking over each other.
///
/// Silence costs nothing: LiveKit's senders use DTX, so in a pause packets
/// stop coming while the sequence numbers stay contiguous. The buffer runs dry,
/// plays silence, and waits for three new packets before resuming.
///
/// Not thread-safe; AudioPipeline only touches it from its own queue.
final class JitterBuffer {
  enum Slot {
    case packet(Data)
    case lost  // a gap in the sequence: conceal it
    case empty  // nothing to play: silence
  }

  private let target: Int
  private let maxDepth: Int
  private var packets: [UInt16: Data] = [:]
  private var nextSeq: UInt16?
  private var playing = false

  init(target: Int = 3, maxDepth: Int = 10) {
    self.target = target
    self.maxDepth = maxDepth
  }

  func push(seq: UInt16, payload: Data) {
    if let next = nextSeq, playing, Self.isBefore(seq, next) {
      return  // its slot has already been played
    }
    packets[seq] = payload
    if packets.count > maxDepth {
      // Too far behind: drop the oldest down to the target depth.
      let ordered = sortedKeys()
      for key in ordered.prefix(packets.count - target) { packets.removeValue(forKey: key) }
      nextSeq = sortedKeys().first
    }
  }

  func pop() -> Slot {
    if !playing {
      guard packets.count >= target else { return .empty }
      playing = true
      nextSeq = sortedKeys().first
    }
    guard let next = nextSeq else { return .empty }
    if let payload = packets.removeValue(forKey: next) {
      nextSeq = next &+ 1
      return .packet(payload)
    }
    if packets.isEmpty {
      playing = false  // dry (DTX pause or underrun): rebuffer
      return .empty
    }
    nextSeq = next &+ 1
    return .lost
  }

  func reset() {
    packets.removeAll()
    nextSeq = nil
    playing = false
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
