import Foundation

/// What the bridge tells the call. Delivered on the main actor, except audio,
/// which arrives on URLSession's delegate queue and goes straight to the audio
/// pipeline.
@MainActor
protocol BridgeClientDelegate: AnyObject {
  func bridgeReady(_ client: BridgeClient, resumed: Bool)
  func bridge(_ client: BridgeClient, callState: String, endedBy: String)
  func bridge(_ client: BridgeClient, peerPresent: Bool)
  func bridge(_ client: BridgeClient, errorCode: String, message: String)
  func bridgeClosed(_ client: BridgeClient)
}

/// One WebSocket to deploy/watch-bridge for one call. The wire format is
/// documented in deploy/watch-bridge/protocol.go; in short: JSON text frames
/// for control, binary frames [kind=1][seq u16][ts u32][Opus packet] for audio.
///
/// A client is single-use. When its socket dies it reports bridgeClosed once
/// and is done; CallController decides whether to dial a new one, and the
/// bridge re-attaches the new socket to the room seat it is still holding.
///
/// watchOS only allows a WebSocket while the app has an active CallKit call
/// (Apple TN3135), so this must only be opened once CallKit has the call.
final class BridgeClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
  weak var delegate: BridgeClientDelegate?

  /// Downlink audio: (seq, ts, Opus packet). Called on URLSession's queue.
  var onAudio: ((UInt16, UInt32, Data) -> Void)?

  /// Echo test only: the round trip of each frame that comes back, in seconds.
  /// Works because /bridge/echo returns uplink frames byte for byte, seq and
  /// all. Called on URLSession's queue.
  var onRoundTrip: ((TimeInterval) -> Void)?
  private var sentAt: [UInt16: TimeInterval] = [:]

  private let url: URL
  private let hello: [String: Any]
  private var session: URLSession!
  private var task: URLSessionWebSocketTask?
  private let lock = NSLock()
  private var closed = false
  private var opened = false
  private var seq: UInt16 = 0
  private var ts: UInt32 = 0
  private var inFlight = 0
  private var pingTimer: Timer?

  /// Above this many unacknowledged uplink frames (~300 ms) new ones are
  /// dropped: URLSession would queue them without limit, and a stalled link
  /// would otherwise come back speaking from seconds ago.
  private let maxInFlight = 15

  init(url: URL, token: String, callId: String?) {
    self.url = url
    var hello: [String: Any] = ["type": "hello", "v": 1, "token": token]
    if let callId { hello["callId"] = callId }
    self.hello = hello
    super.init()
    let cfg = URLSessionConfiguration.default
    // Doubles as the idle timeout on a WebSocket: keep it well above the ping
    // interval, or a quiet stretch (dialing, muted) reads as a dead link.
    cfg.timeoutIntervalForRequest = 30
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
  }

  func connect() {
    let task = session.webSocketTask(with: url)
    task.maximumMessageSize = 64 * 1024
    self.task = task
    task.resume()
    sendJSON(hello)
    receive()
    DispatchQueue.main.async {
      self.pingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
        self?.ping()
      }
    }
  }

  /// One encoded 20 ms uplink packet. Called from the audio queue.
  func sendAudio(_ packet: Data) {
    lock.lock()
    if closed || !opened || inFlight >= maxInFlight {
      lock.unlock()
      return
    }
    inFlight += 1
    seq &+= 1
    ts &+= 960
    var frame = Data(capacity: 7 + packet.count)
    frame.append(0x01)
    frame.append(UInt8(seq >> 8))
    frame.append(UInt8(seq & 0xff))
    frame.append(UInt8((ts >> 24) & 0xff))
    frame.append(UInt8((ts >> 16) & 0xff))
    frame.append(UInt8((ts >> 8) & 0xff))
    frame.append(UInt8(ts & 0xff))
    frame.append(packet)
    if onRoundTrip != nil {
      sentAt[seq] = ProcessInfo.processInfo.systemUptime
      if sentAt.count > 500 { sentAt.removeAll() }
    }
    lock.unlock()

    task?.send(.data(frame)) { [weak self] _ in
      guard let self else { return }
      self.lock.lock()
      self.inFlight -= 1
      self.lock.unlock()
    }
  }

  func sendMute(_ muted: Bool) {
    sendJSON(["type": "mute", "muted": muted])
  }

  /// Leave the room now (the call is over), then close.
  func bye() {
    sendJSON(["type": "bye"])
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.close() }
  }

  /// Drop the socket without telling the bridge anything; it holds the seat
  /// for its grace window.
  func close() {
    lock.lock()
    let wasClosed = closed
    closed = true
    lock.unlock()
    guard !wasClosed else { return }
    DispatchQueue.main.async {
      self.pingTimer?.invalidate()
      self.pingTimer = nil
    }
    task?.cancel(with: .normalClosure, reason: nil)
    session.invalidateAndCancel()
  }

  // MARK: - internals

  private func sendJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
      let text = String(data: data, encoding: .utf8)
    else { return }
    task?.send(.string(text)) { error in
      if let error { Log.error("bridge send", error) }
    }
  }

  private func receive() {
    task?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        self.finish(reason: error.localizedDescription)
      case .success(let message):
        switch message {
        case .data(let data):
          self.handleAudio(data)
        case .string(let text):
          self.handleControl(text)
        @unknown default:
          break
        }
        self.receive()
      }
    }
  }

  private func handleAudio(_ data: Data) {
    guard data.count > 7, data[data.startIndex] == 0x01 else { return }
    let b = [UInt8](data.prefix(7))
    let seq = UInt16(b[1]) << 8 | UInt16(b[2])
    let ts = UInt32(b[3]) << 24 | UInt32(b[4]) << 16 | UInt32(b[5]) << 8 | UInt32(b[6])
    if let onRoundTrip {
      lock.lock()
      let sent = sentAt.removeValue(forKey: seq)
      lock.unlock()
      if let sent { onRoundTrip(ProcessInfo.processInfo.systemUptime - sent) }
    }
    onAudio?(seq, ts, data.subdata(in: (data.startIndex + 7)..<data.endIndex))
  }

  private func handleControl(_ text: String) {
    guard let data = text.data(using: .utf8),
      let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let type = msg["type"] as? String
    else { return }

    if type == "ready" {
      lock.lock()
      opened = true
      lock.unlock()
    }
    Task { @MainActor in
      guard let delegate = self.delegate else { return }
      switch type {
      case "ready":
        delegate.bridgeReady(self, resumed: msg["resumed"] as? Bool ?? false)
      case "state":
        delegate.bridge(
          self, callState: msg["state"] as? String ?? "", endedBy: msg["endedBy"] as? String ?? "")
      case "peer":
        delegate.bridge(self, peerPresent: msg["present"] as? Bool ?? false)
      case "error":
        delegate.bridge(
          self, errorCode: msg["code"] as? String ?? "internal",
          message: msg["message"] as? String ?? "")
      default:
        break
      }
    }
  }

  private func ping() {
    task?.sendPing { [weak self] error in
      if let error { self?.finish(reason: "ping: \(error.localizedDescription)") }
    }
  }

  private func finish(reason: String) {
    lock.lock()
    let wasClosed = closed
    closed = true
    lock.unlock()
    guard !wasClosed else { return }
    Log.info("bridge socket closed: \(reason)")
    DispatchQueue.main.async {
      self.pingTimer?.invalidate()
      self.pingTimer = nil
    }
    task?.cancel(with: .goingAway, reason: nil)
    session.finishTasksAndInvalidate()
    Task { @MainActor in self.delegate?.bridgeClosed(self) }
  }

  // MARK: - URLSessionWebSocketDelegate

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    finish(reason: "closed by server (\(closeCode.rawValue))")
  }
}
