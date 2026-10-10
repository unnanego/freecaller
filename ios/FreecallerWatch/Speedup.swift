import Foundation

/// Plays decoded audio a little faster, without changing its pitch, so the
/// watch can work off a backlog instead of carrying the delay for the rest of
/// the call.
///
/// Why it is needed: the downlink crosses TCP, and through the iPhone's
/// Bluetooth link the watch stalls for about a second every few seconds. TCP
/// loses nothing, so after each stall everything behind it arrives late, and
/// the delay stays unless something is thrown away. Skipping only silent
/// packets was not enough — a caller with background noise never sends any
/// (build 25: the backlog grew past 3 s and then lost 2.6 s at once).
/// AVAudioUnitTimePitch would do this, but it does not exist on watchOS.
///
/// How: from each 20 ms frame, cut out one pitch period — the lag at which the
/// waveform best repeats itself — and crossfade across the cut, so the voice
/// keeps its pitch and nothing clicks. Quiet frames are simply halved.
enum Speedup {
  /// Crossfade length: 2.5 ms at 48 kHz.
  static let fade = 120
  /// Pitch-period search range: 2.5–10 ms (100–400 Hz voices).
  static let minLag = 120
  static let maxLag = 480
  /// Below this RMS a frame is a pause; cut it in half.
  static let quietRMS: Float = 0.01

  /// Shortens `samples[0..<count]` in place; returns the new length.
  static func compress(_ samples: UnsafeMutablePointer<Float>, count: Int) -> Int {
    guard count >= maxLag + 2 * fade else { return count }

    var energy: Float = 0
    for i in 0..<count { energy += samples[i] * samples[i] }
    let rms = (energy / Float(count)).squareRoot()

    // Cut point: early enough that the search fits in the frame.
    let start = fade
    let lag: Int
    if rms < quietRMS {
      lag = min(count / 2, count - start - fade)
    } else {
      // The lag whose window looks most like the one at `start`.
      var best = minLag
      var bestScore = -Float.infinity
      var l = minLag
      while l <= maxLag, start + l + fade <= count {
        var dot: Float = 0, norm: Float = 0
        for i in 0..<fade {
          let b = samples[start + l + i]
          dot += samples[start + i] * b
          norm += b * b
        }
        let score = norm > 0 ? dot / norm.squareRoot() : -Float.infinity
        if score > bestScore {
          bestScore = score
          best = l
        }
        l += 2
      }
      lag = best
    }

    // Crossfade the window at `start` into the one `lag` later, then close the gap.
    for i in 0..<fade {
      let w = Float(i) / Float(fade)
      samples[start + i] = samples[start + i] * (1 - w) + samples[start + lag + i] * w
    }
    let tail = start + fade
    let moved = count - (tail + lag)
    if moved > 0 {
      (samples + tail).update(from: samples + tail + lag, count: moved)
    }
    return count - lag
  }
}
