import AVFoundation

/// Microphone → Opus → bridge, and bridge → jitter buffer → Opus → speaker.
///
/// Runs only between CallKit's didActivate and didDeactivate: CallKit owns the
/// audio session for a call, configured in CallController.configureAudioSession
/// before the call starts and activated by the system.
///
/// Echo is the hard part on a watch — the speaker and the mic are centimetres
/// apart — and is handled by the system's voice processing (the same echo
/// canceller FaceTime uses), switched on with setVoiceProcessingEnabled. How
/// well that works on the wrist is half of what spike 1 measures.
///
/// Threads: everything below runs on `queue`, a serial queue. The mic tap
/// arrives on an audio I/O thread and hops onto it; the bridge's downlink does
/// the same. The player is fed by its own completion callbacks, so the playout
/// clock is the audio hardware's, not a timer's.
final class AudioPipeline {
  enum Tone { case none, ringback, busy }

  static let frameSamples = 960  // 20 ms at 48 kHz

  /// Each encoded 20 ms uplink packet. Called on the pipeline's queue.
  var onPacket: ((Data) -> Void)?

  let pcmFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

  private let queue = DispatchQueue(label: "com.unnanego.freecaller.watch.audio", qos: .userInteractive)
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var micConverter: AVAudioConverter?
  private var encoder: OpusEncoder?
  private var decoder: OpusDecoder?
  private var pending: [Float] = []
  private let jitter = JitterBuffer()
  private var running = false
  private var muted = false
  private var tone: Tone = .none
  private var toneSample = 0
  /// Bumped on every start/stop/restart. A player's completion callbacks keep
  /// firing after it is stopped, and a stale one that reached a NEW player
  /// would start a second self-perpetuating chain of buffers — permanent extra
  /// delay. Each chain carries the generation it was born in.
  private var generation = 0
  private var configObserver: NSObjectProtocol?

  /// Builds the codecs without touching the audio hardware, so a missing Opus
  /// codec is known before any call is placed (the Diagnostics screen shows it).
  static func codecCheck() -> String? {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    do {
      let enc = try OpusEncoder(pcm: format)
      _ = try OpusDecoder(pcm: format)
      guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960) else { return "no buffer" }
      buf.frameLength = 960
      // Priming may swallow the first buffer or two; a few is enough to know.
      for _ in 0..<4 where enc.encode(buf) != nil { return nil }
      return "encoder produced no packets"
    } catch {
      return "\(error)"
    }
  }

  // MARK: - lifecycle

  func start() throws {
    var thrown: Error?
    queue.sync {
      do { try self.startOnQueue() } catch { thrown = error }
    }
    if let thrown { throw thrown }
  }

  private func startOnQueue() throws {
    guard !running else { return }
    encoder = try OpusEncoder(pcm: pcmFormat)
    decoder = try OpusDecoder(pcm: pcmFormat)

    let engine = AVAudioEngine()
    let input = engine.inputNode
    do {
      try input.setVoiceProcessingEnabled(true)
    } catch {
      Log.error("voice processing (echo cancellation) unavailable", error)
    }

    let inFormat = input.outputFormat(forBus: 0)
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
      throw CodecError.unavailable("microphone has no input format (permission?)")
    }
    micConverter = AVAudioConverter(from: inFormat, to: pcmFormat)
    input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
      self?.queue.async { self?.handleMic(buffer) }
    }

    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
    engine.prepare()
    try engine.start()
    player.play()

    self.engine = engine
    self.player = player
    running = true
    generation &+= 1
    pending.removeAll()
    // Three 20 ms buffers in flight: enough to never starve the player, short
    // enough not to add noticeable delay.
    for _ in 0..<3 { scheduleNext() }

    // A route change (headphones connecting, say) stops the engine; without a
    // restart the call goes silent until it ends.
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      self?.queue.async { self?.restartAfterConfigurationChange() }
    }
    Log.info("audio started (mic \(Int(inFormat.sampleRate)) Hz)")
  }

  func stop() {
    queue.sync {
      guard running else { return }
      running = false
      generation &+= 1
      if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
      configObserver = nil
      engine?.inputNode.removeTap(onBus: 0)
      player?.stop()
      engine?.stop()
      engine = nil
      player = nil
      micConverter = nil
      encoder = nil
      decoder = nil
      jitter.reset()
      pending.removeAll()
      tone = .none
      Log.info("audio stopped")
    }
  }

  func setMuted(_ value: Bool) {
    queue.async { self.muted = value }
  }

  func setTone(_ value: Tone) {
    queue.async {
      if self.tone != value { self.toneSample = 0 }
      self.tone = value
    }
  }

  /// A downlink packet from the bridge. Any thread.
  func receive(seq: UInt16, payload: Data) {
    queue.async { self.jitter.push(seq: seq, payload: payload) }
  }

  /// Forget buffered downlink audio (after a bridge reconnect: the sequence
  /// numbers carry on, but what was queued is stale).
  func resetPlayout() {
    queue.async { self.jitter.reset() }
  }

  // MARK: - uplink

  private func handleMic(_ buffer: AVAudioPCMBuffer) {
    guard running, let converter = micConverter else { return }

    let ratio = pcmFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return }
    var fed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if fed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      fed = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, let samples = out.floatChannelData?[0] else { return }
    pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))

    let n = Self.frameSamples
    while pending.count >= n {
      defer { pending.removeFirst(n) }
      if muted { continue }  // the mute is real: nothing leaves the watch
      guard let frame = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(n)),
        let dst = frame.floatChannelData?[0]
      else { continue }
      frame.frameLength = AVAudioFrameCount(n)
      pending.withUnsafeBufferPointer { src in
        dst.update(from: src.baseAddress!, count: n)
      }
      if let packet = encoder?.encode(frame) {
        onPacket?(packet)
      }
    }
  }

  // MARK: - downlink

  private func scheduleNext() {
    guard running, let player else { return }
    let buffer = nextBuffer()
    let born = generation
    player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataConsumed) {
      [weak self] _ in
      self?.queue.async {
        guard let self, self.generation == born else { return }
        self.scheduleNext()
      }
    }
  }

  private func restartAfterConfigurationChange() {
    guard running, let engine, let player else { return }
    Log.info("audio configuration changed — restarting the engine")
    generation &+= 1
    do {
      try engine.start()
      player.play()
      for _ in 0..<3 { scheduleNext() }
    } catch {
      Log.error("audio restart failed", error)
    }
  }

  private func nextBuffer() -> AVAudioPCMBuffer {
    if tone != .none { return toneBuffer() }
    switch jitter.pop() {
    case .packet(let data):
      if let pcm = decoder?.decode(data) { return pcm }
      return silence()
    case .lost, .empty:
      return silence()
    }
  }

  private func silence() -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(Self.frameSamples))!
    buf.frameLength = AVAudioFrameCount(Self.frameSamples)
    if let data = buf.floatChannelData?[0] {
      data.initialize(repeating: 0, count: Self.frameSamples)
    }
    return buf
  }

  /// Russian network tones (GOST): 425 Hz; ringback 1 s on / 4 s off, busy
  /// 0.35 s on / 0.35 s off — what a Russian ear expects to hear.
  private func toneBuffer() -> AVAudioPCMBuffer {
    let buf = silence()
    guard let data = buf.floatChannelData?[0] else { return buf }
    let rate = 48000.0
    let (on, period): (Int, Int) =
      tone == .ringback ? (48000, 5 * 48000) : (Int(0.35 * rate), Int(0.7 * rate))
    for i in 0..<Self.frameSamples {
      let t = toneSample + i
      if t % period < on {
        data[i] = Float(0.15 * sin(2 * Double.pi * 425 * Double(t) / rate))
      }
    }
    toneSample += Self.frameSamples
    return buf
  }
}
