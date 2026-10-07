import AVFoundation
import AudioToolbox

enum CodecError: Error {
  case unavailable(String)
}

/// Opus through Apple's own codec (AVAudioConverter + kAudioFormatOpus).
///
/// Opus is what LiveKit already carries, so packets cross the bridge untouched
/// — the bridge never decodes anything (deploy/watch-bridge). Whether Apple's
/// Opus encoder is present on watchOS is exactly what spike 1 in
/// docs/watch-plan.md finds out: if `OpusEncoder.init` throws on the device,
/// plan B is libopus compiled for watchOS behind these same two types, and
/// nothing else in the app changes.
///
/// Both work in 48 kHz mono Float32 and 20 ms packets (960 samples).
final class OpusEncoder {
  private let converter: AVAudioConverter
  private let opusFormat: AVAudioFormat

  init(pcm: AVAudioFormat) throws {
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
      mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
      mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
    guard let opus = AVAudioFormat(streamDescription: &asbd) else {
      throw CodecError.unavailable("no Opus AVAudioFormat")
    }
    guard let converter = AVAudioConverter(from: pcm, to: opus) else {
      throw CodecError.unavailable("no PCM→Opus converter on this device")
    }
    // Speech on a small speaker: 24 kb/s is transparent for voice and leaves
    // headroom on a weak LTE link.
    converter.bitRate = 24_000
    self.converter = converter
    self.opusFormat = opus
  }

  /// Encode exactly one 20 ms buffer. nil while the encoder is still priming,
  /// or on error.
  func encode(_ pcm: AVAudioPCMBuffer) -> Data? {
    let out = AVAudioCompressedBuffer(
      format: opusFormat, packetCapacity: 1,
      maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
    var fed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if fed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      fed = true
      inputStatus.pointee = .haveData
      return pcm
    }
    guard status != .error, out.packetCount > 0 else {
      if let error { Log.error("opus encode", error) }
      return nil
    }
    let size = out.packetDescriptions.map { Int($0[0].mDataByteSize) } ?? Int(out.byteLength)
    guard size > 0 else { return nil }
    return Data(bytes: out.data, count: size)
  }
}

final class OpusDecoder {
  private let converter: AVAudioConverter
  private let opusFormat: AVAudioFormat
  private let pcm: AVAudioFormat

  init(pcm: AVAudioFormat) throws {
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
      mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
      mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
    guard let opus = AVAudioFormat(streamDescription: &asbd) else {
      throw CodecError.unavailable("no Opus AVAudioFormat")
    }
    guard let converter = AVAudioConverter(from: opus, to: pcm) else {
      throw CodecError.unavailable("no Opus→PCM converter on this device")
    }
    self.converter = converter
    self.opusFormat = opus
    self.pcm = pcm
  }

  /// Decode one packet (any Opus frame size up to 120 ms).
  func decode(_ packet: Data) -> AVAudioPCMBuffer? {
    let input = AVAudioCompressedBuffer(
      format: opusFormat, packetCapacity: 1, maximumPacketSize: max(packet.count, 1500))
    packet.withUnsafeBytes { raw in
      if let base = raw.baseAddress {
        input.data.copyMemory(from: base, byteCount: packet.count)
      }
    }
    input.byteLength = UInt32(packet.count)
    input.packetCount = 1
    input.packetDescriptions?[0] = AudioStreamPacketDescription(
      mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))

    // 120 ms at 48 kHz is the largest Opus packet there is.
    guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 5760) else { return nil }
    var fed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if fed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      fed = true
      inputStatus.pointee = .haveData
      return input
    }
    guard status != .error, out.frameLength > 0 else {
      if let error { Log.error("opus decode", error) }
      return nil
    }
    return out
  }
}
