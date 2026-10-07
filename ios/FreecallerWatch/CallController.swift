import AVFoundation
import CallKit
import PushKit

/// The watch's call state machine: CallKit + PushKit + PocketBase + the bridge.
///
/// The watch counterpart of lib/services/call_engine.dart, and deliberately
/// writes the same states with the same ownership the server enforces
/// (pb_hooks/calls.pb.js):
///
///   outgoing   create `ringing` → (peer) accepted → `ended` by whoever hangs up
///              we give up while ringing → `cancelled`; 45 s → `missed`
///   incoming   answer → `accepted` (+ answeredOn) ; refuse → `declined`
///              (+ answeredOn) ; hang up later → `ended`
///
/// One call at a time. Everything runs on the main actor; CallKit and PushKit
/// both deliver on the main queue (configured below), which is what makes
/// MainActor.assumeIsolated in their callbacks sound.
@MainActor
final class CallController: NSObject, ObservableObject {
  static let shared = CallController()

  enum Phase: Equatable {
    case idle
    case dialing  // outgoing, ringing at the other end
    case ringing  // incoming, ringing here
    case connecting  // answered, joining
    case inCall
    case reconnecting  // bridge socket dropped mid-call
  }

  struct ActiveCall {
    let uuid: UUID
    let callId: String
    let peerName: String
    let outgoing: Bool
    let isEcho: Bool
    /// Outgoing: the peer answered. Incoming: we answered.
    var accepted = false
    var connectedAt: Date?
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var call: ActiveCall?
  @Published private(set) var muted = false
  @Published private(set) var peerPresent = false
  @Published var lastError: String?
  @Published private(set) var echoSummary = ""
  @Published private(set) var pushRegistered = false

  private let provider: CXProvider
  private let callController = CXCallController()
  private var registry: PKPushRegistry?
  private let audio = AudioPipeline()
  private var bridge: BridgeClient?
  /// The bridge as seen from the audio queue, which must not touch `bridge`.
  private let uplink = Locked<BridgeClient?>(nil)
  private var voipToken: String?
  private var ringTimer: Timer?
  private var ringPoll: Timer?
  private var reconnectDeadline: Date?
  private var bridgeFatal = false
  private var pendingOutgoing: (uuid: UUID, name: String, calleeId: String, isEcho: Bool)?
  private var echoSamples: [Double] = []

  private var session: AppSession { AppSession.shared }

  private override init() {
    let config = CXProviderConfiguration()
    config.supportsVideo = false
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic, .phoneNumber]
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)  // nil = main queue
    audio.onPacket = { [uplink] packet in uplink.value?.sendAudio(packet) }
  }

  /// At launch — including a background launch by a VoIP push, which is why
  /// this lives in the app delegate and not in a view.
  func start() {
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    self.registry = registry

    session.onAccountChanged = { [weak self] in self?.registerDevice() }
    session.onWillSignOut = { userId, token, deviceId in
      // Stop ringing for an account this watch is leaving. Best effort: the
      // devices hook also hands the row over on the next registration.
      Task { try? await PocketBase.shared.deleteDevice(userId: userId, deviceId: deviceId, token: token) }
    }
  }

  // MARK: - user actions

  func startCall(to contact: Contact) {
    guard call == nil, pendingOutgoing == nil, session.isSignedIn else { return }
    let handle = CXHandle(type: .generic, value: contact.phone.isEmpty ? contact.uid : contact.phone)
    request(start: handle, name: contact.displayName, calleeId: contact.uid, isEcho: false)
  }

  /// Spike 1: a call to /bridge/echo instead of a person. It has to be a real
  /// CallKit call — watchOS only allows the socket during one.
  func startEchoTest() {
    guard call == nil, pendingOutgoing == nil, session.isSignedIn else { return }
    echoSamples.removeAll()
    echoSummary = ""
    request(start: CXHandle(type: .generic, value: "echo"), name: "Тест эха", calleeId: "", isEcho: true)
  }

  func hangUp() {
    guard let call else { return }
    callController.request(CXTransaction(action: CXEndCallAction(call: call.uuid))) { error in
      if let error {
        Task { @MainActor in
          Log.error("end call refused", error)
          self.endWithWrite(reason: .failed)
        }
      }
    }
  }

  /// Answer from our own screen (the system's incoming-call UI does the same).
  func answer() {
    guard let call, !call.outgoing, !call.accepted else { return }
    callController.request(CXTransaction(action: CXAnswerCallAction(call: call.uuid))) { error in
      if let error { Task { @MainActor in Log.error("answer refused", error) } }
    }
  }

  func toggleMute() {
    guard let call else { return }
    let action = CXSetMutedCallAction(call: call.uuid, muted: !muted)
    callController.request(CXTransaction(action: action)) { _ in }
  }

  private func request(start handle: CXHandle, name: String, calleeId: String, isEcho: Bool) {
    let uuid = UUID()
    pendingOutgoing = (uuid, name, calleeId, isEcho)
    let action = CXStartCallAction(call: uuid, handle: handle)
    action.isVideo = false
    action.contactIdentifier = calleeId.isEmpty ? nil : calleeId
    callController.request(CXTransaction(action: action)) { error in
      guard let error else { return }
      Task { @MainActor in
        Log.error("start call refused by the system", error)
        self.lastError = "Не удалось позвонить"
        self.pendingOutgoing = nil
      }
    }
  }

  // MARK: - push registration

  func registerDevice() {
    guard let voip = voipToken, session.isSignedIn, let token = session.token else { return }
    let uid = session.userId
    let deviceId = session.deviceId
    Task {
      do {
        try await PocketBase.shared.upsertDevice(userId: uid, deviceId: deviceId, voipToken: voip, token: token)
        self.pushRegistered = true
        Log.info("push registered")
      } catch let error as PBError where error.status == 401 {
        self.session.tokenRejected()
      } catch {
        Log.error("push registration failed", error)
      }
    }
  }

  // MARK: - incoming push

  private func handlePush(_ dict: [AnyHashable: Any], completion: @escaping @Sendable () -> Void) {
    let name = (dict["callerName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Config.appName

    // CallKit takes only UUIDs, and Apple wants a call reported for EVERY VoIP
    // push, garbage included — failing that gets the app killed and its pushes
    // throttled. Same rules as the iPhone's AppDelegate.
    guard let callId = dict["callId"] as? String, let uuid = UUID(uuidString: callId) else {
      reportAndEnd(UUID(), name: name, reason: .failed, completion: completion)
      return
    }

    if dict["cancel"] as? String == "true" {
      if let c = call, c.uuid == uuid {
        // Apple wants a report for every VoIP push; for a UUID CallKit already
        // holds it fails harmlessly with "already exists", and that is enough.
        provider.reportNewIncomingCall(with: uuid, update: CXCallUpdate()) { _ in }
        if !c.outgoing && !c.accepted { remoteEnded(reason: .remoteEnded) }
        // A cancel for the call we are ON is never sent (the server skips the
        // device named in answeredOn); if one arrives anyway, keep the call.
        completion()
        return
      }
      reportAndEnd(uuid, name: name, reason: .remoteEnded, completion: completion)
      return
    }

    guard call == nil, pendingOutgoing == nil, session.isSignedIn else {
      // Busy, or not signed in: report and drop. The caller's other routes
      // (this user's phone) still ring.
      reportAndEnd(uuid, name: name, reason: .unanswered, completion: completion)
      return
    }

    let handleValue =
      (dict["callerPhone"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? (dict["callerId"] as? String) ?? callId
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: handleValue)
    update.localizedCallerName = name
    update.hasVideo = false
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false

    call = ActiveCall(uuid: uuid, callId: callId, peerName: name, outgoing: false, isEcho: false)
    phase = .ringing
    configureAudioSession()
    provider.reportNewIncomingCall(with: uuid, update: update) { error in
      Task { @MainActor in
        if let error {
          // Do Not Disturb, a filtered caller, or a duplicate.
          Log.error("incoming call refused by the system", error)
          if self.call?.uuid == uuid { self.finishLocally() }
        } else {
          Log.info("ringing: \(name)")
          self.startRingWatch()
        }
        completion()
      }
    }
  }

  private func reportAndEnd(
    _ uuid: UUID, name: String, reason: CXCallEndedReason, completion: @escaping @Sendable () -> Void
  ) {
    let update = CXCallUpdate()
    update.localizedCallerName = name
    update.remoteHandle = CXHandle(type: .generic, value: name)
    provider.reportNewIncomingCall(with: uuid, update: update) { error in
      Task { @MainActor in
        // An error here is usually "UUID already exists": a duplicate push for
        // the call that is ringing or up. Ending that UUID would hang it up.
        if error == nil { self.provider.reportCall(with: uuid, endedAt: nil, reason: reason) }
        completion()
      }
    }
  }

  /// While an incoming call rings, follow its record: the caller may give up
  /// (their cancel push can be lost) or another of this user's devices may
  /// answer. The phone app does the same through its call watch.
  private func startRingWatch() {
    ringPoll?.invalidate()
    ringPoll = Timer.scheduledTimer(withTimeInterval: Config.ringPollInterval, repeats: true) { _ in
      Task { @MainActor in await self.checkRinging() }
    }
    ringTimer?.invalidate()
    ringTimer = Timer.scheduledTimer(withTimeInterval: Config.ringTimeout + 10, repeats: false) { _ in
      Task { @MainActor in
        if let c = self.call, !c.outgoing, !c.accepted { self.remoteEnded(reason: .unanswered) }
      }
    }
  }

  private func checkRinging() async {
    guard let c = call, !c.outgoing, !c.accepted, let token = session.token else { return }
    do {
      let record = try await PocketBase.shared.getCall(c.callId, token: token)
      guard let now = call, now.uuid == c.uuid, !now.accepted else { return }
      switch record.state {
      case "ringing": return
      case "accepted": remoteEnded(reason: .answeredElsewhere)
      case "declined": remoteEnded(reason: .declinedElsewhere)
      case "missed": remoteEnded(reason: .unanswered)
      default: remoteEnded(reason: .remoteEnded)
      }
    } catch let error as PBError where error.status == 401 {
      session.tokenRejected()
    } catch {
      // Offline for a moment; the next tick tries again.
    }
  }

  // MARK: - CallKit actions

  private func performStart(_ action: CXStartCallAction) {
    guard let pending = pendingOutgoing, pending.uuid == action.callUUID else {
      action.fail()
      return
    }
    pendingOutgoing = nil
    configureAudioSession()

    let uuid = action.callUUID
    let callId = uuid.uuidString.lowercased()  // the format the phones use
    call = ActiveCall(uuid: uuid, callId: callId, peerName: pending.name, outgoing: true, isEcho: pending.isEcho)
    phase = .dialing
    peerPresent = false

    let update = CXCallUpdate()
    update.remoteHandle = action.handle
    update.localizedCallerName = pending.name
    update.hasVideo = false
    provider.reportCall(with: uuid, updated: update)
    provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)

    if pending.isEcho {
      action.fulfill()
      openBridge()
      return
    }

    guard let token = session.token else {
      action.fail()
      finishLocally()
      return
    }
    let me = session.userId
    Task {
      do {
        try await PocketBase.shared.createCall(
          callId: callId, callerId: me, calleeId: pending.calleeId, token: token)
        guard self.call?.uuid == uuid else {
          // Hung up while the create was on the wire: the record now exists
          // and is ringing someone. Close it.
          action.fail()
          try? await PocketBase.shared.setState(callId, "cancelled", token: token)
          return
        }
        action.fulfill()
        Log.info("dialing \(pending.name)")
        self.openBridge()
        self.ringTimer?.invalidate()
        self.ringTimer = Timer.scheduledTimer(withTimeInterval: Config.ringTimeout, repeats: false) { _ in
          Task { @MainActor in self.outgoingTimedOut() }
        }
      } catch {
        Log.error("could not create the call", error)
        action.fail()
        // A timeout can hide a create that landed, which would ring the callee
        // for 45 s with nobody on this end. A 4xx means it surely did not.
        let status = (error as? PBError)?.status ?? 0
        if !(400..<500).contains(status) {
          Task { try? await PocketBase.shared.setState(callId, "cancelled", token: token) }
        }
        if (error as? PBError)?.status == 401 { self.session.tokenRejected() }
        self.lastError = "Не удалось позвонить"
        if self.call?.uuid == uuid { self.finishLocally() }
      }
    }
  }

  private func outgoingTimedOut() {
    guard let c = call, c.outgoing, !c.accepted, !c.isEcho else { return }
    Log.info("no answer after \(Int(Config.ringTimeout))s")
    let callId = c.callId
    let me = session.userId
    if let token = session.token {
      Task {
        do {
          try await PocketBase.shared.setState(callId, "missed", token: token)
        } catch {
          // Refused: they answered in the same instant. The record is now
          // `accepted` with them alone in the room, so close it properly.
          if let record = try? await PocketBase.shared.getCall(callId, token: token),
            record.state == "accepted"
          {
            try? await PocketBase.shared.setState(callId, "ended", token: token, endedBy: me)
          }
        }
      }
    }
    remoteEnded(reason: .unanswered)
  }

  private func performAnswer(_ action: CXAnswerCallAction) {
    guard var c = call, c.uuid == action.callUUID, !c.outgoing, let token = session.token else {
      action.fail()
      return
    }
    c.accepted = true
    call = c
    ringPoll?.invalidate()
    ringTimer?.invalidate()
    phase = .connecting
    action.fulfill()

    let uuid = c.uuid
    let callId = c.callId
    let deviceId = session.deviceId
    Task {
      do {
        try await PocketBase.shared.setState(callId, "accepted", token: token, answeredOn: deviceId)
      } catch {
        // Refused: usually the caller gave up or another device answered first.
        // But a network error can hide an accept that DID land — the record
        // says whose it was.
        let record = try? await PocketBase.shared.getCall(callId, token: token)
        guard record?.state == "accepted", record?.answeredOn == deviceId else {
          Log.error("accept refused", error)
          if self.call?.uuid == uuid {
            self.remoteEnded(reason: record?.state == "accepted" ? .answeredElsewhere : .failed)
          }
          return
        }
      }
      guard self.call?.uuid == uuid else { return }
      Log.info("answered")
      self.openBridge()
    }
  }

  private func performEnd(_ action: CXEndCallAction) {
    action.fulfill()
    guard let c = call, c.uuid == action.callUUID else { return }
    writeTerminalState(for: c)
    finishLocally()
  }

  private func performSetMuted(_ action: CXSetMutedCallAction) {
    muted = action.isMuted
    audio.setMuted(muted)
    bridge?.sendMute(muted)
    action.fulfill()
  }

  // MARK: - audio session

  private func configureAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
    } catch {
      Log.error("audio session category", error)
    }
  }

  private func audioActivated() {
    do {
      try audio.start()
    } catch {
      Log.error("audio failed to start", error)
      lastError = "Нет звука: \(error)"
      hangUp()
      return
    }
    audio.setMuted(muted)
    if let c = call, c.outgoing, !c.accepted, !c.isEcho { audio.setTone(.ringback) }
  }

  // MARK: - bridge

  private func openBridge() {
    guard let c = call else { return }
    guard let token = session.token else {
      endWithWrite(reason: .failed)
      return
    }
    bridgeFatal = false
    let client = BridgeClient(
      url: c.isEcho ? Config.echoURL : Config.bridgeURL, token: token,
      callId: c.isEcho ? nil : c.callId)
    client.delegate = self
    client.onAudio = { [audio] seq, _, payload in audio.receive(seq: seq, payload: payload) }
    if c.isEcho {
      client.onRoundTrip = { rtt in Task { @MainActor in self.recordRoundTrip(rtt) } }
    }
    bridge = client
    uplink.value = client
    client.connect()
  }

  private func closeBridge(bye: Bool) {
    uplink.value = nil
    if bye { bridge?.bye() } else { bridge?.close() }
    bridge = nil
  }

  private func markConnected() {
    guard var c = call else { return }
    if c.connectedAt == nil {
      c.connectedAt = Date()
      call = c
    }
    phase = .inCall
  }

  private func recordRoundTrip(_ rtt: TimeInterval) {
    echoSamples.append(rtt * 1000)
    if echoSamples.count > 250 { echoSamples.removeFirst(echoSamples.count - 250) }
    let sorted = echoSamples.sorted()
    let median = sorted[sorted.count / 2]
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    echoSummary = "RTT \(Int(median)) мс (p95 \(Int(p95)) мс), \(echoSamples.count) пакетов"
  }

  // MARK: - ending

  /// The state this side owns for the way it is leaving (as
  /// CallEngine._ownedTerminalState on the phone).
  private func writeTerminalState(for c: ActiveCall) {
    guard !c.isEcho else { return }
    if c.accepted {
      write(c.callId, "ended", endedBy: session.userId)
    } else if c.outgoing {
      write(c.callId, "cancelled")
    } else {
      write(c.callId, "declined", answeredOn: session.deviceId)
    }
  }

  private func write(_ callId: String, _ state: String, endedBy: String? = nil, answeredOn: String? = nil) {
    guard let token = session.token else { return }
    Task {
      do {
        try await PocketBase.shared.setState(
          callId, state, token: token, endedBy: endedBy, answeredOn: answeredOn)
      } catch {
        // The server's sweep closes anything left dangling.
        Log.error("writing \(state) failed", error)
      }
    }
  }

  /// End on our side, writing our terminal state, and tell CallKit.
  private func endWithWrite(reason: CXCallEndedReason) {
    guard let c = call else { return }
    writeTerminalState(for: c)
    remoteEnded(reason: reason)
  }

  /// The call ended without a CXEndCallAction (the other side, a timeout, a
  /// failure): tell CallKit, then clean up.
  private func remoteEnded(reason: CXCallEndedReason) {
    guard let c = call else { return }
    provider.reportCall(with: c.uuid, endedAt: nil, reason: reason)
    finishLocally()
  }

  private func finishLocally() {
    ringTimer?.invalidate()
    ringTimer = nil
    ringPoll?.invalidate()
    ringPoll = nil
    reconnectDeadline = nil
    closeBridge(bye: true)
    audio.stop()
    call = nil
    phase = .idle
    muted = false
    peerPresent = false
  }
}

// MARK: - BridgeClientDelegate

extension CallController: BridgeClientDelegate {
  func bridgeReady(_ client: BridgeClient, resumed: Bool) {
    guard client === bridge, let c = call else { return }
    reconnectDeadline = nil
    if resumed {
      audio.resetPlayout()
      Log.info("bridge resumed")
    }
    if c.isEcho || (!c.outgoing && c.accepted) || (c.outgoing && c.accepted) {
      markConnected()
    } else if phase == .reconnecting {
      phase = .dialing
    }
  }

  func bridge(_ client: BridgeClient, callState: String, endedBy: String) {
    guard client === bridge, var c = call else { return }
    switch callState {
    case "accepted":
      guard c.outgoing, !c.accepted else { return }
      c.accepted = true
      call = c
      ringTimer?.invalidate()
      audio.setTone(.none)
      provider.reportOutgoingCall(with: c.uuid, connectedAt: Date())
      Log.info("answered by \(c.peerName)")
      markConnected()
    case "declined":
      guard c.outgoing else { return }
      // The bridge closes the socket next; that is not a drop to redial.
      bridgeFatal = true
      // Let them hear "busy" for a moment, as on a phone, then hang up.
      ringTimer?.invalidate()
      audio.setTone(.busy)
      let uuid = c.uuid
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        if self.call?.uuid == uuid { self.remoteEnded(reason: .remoteEnded) }
      }
    case "ended", "cancelled", "missed":
      bridgeFatal = true
      remoteEnded(reason: .remoteEnded)
    default:
      break
    }
  }

  func bridge(_ client: BridgeClient, peerPresent: Bool) {
    guard client === bridge else { return }
    self.peerPresent = peerPresent
  }

  func bridge(_ client: BridgeClient, errorCode: String, message: String) {
    guard client === bridge else { return }
    Log.error("bridge error \(errorCode): \(message)")
    switch errorCode {
    case "unauthorized":
      bridgeFatal = true
      endWithWrite(reason: .failed)  // while the token is still here to write with
      session.tokenRejected()
    case "conflict":
      // The call is already over (typically the peer hung up while we were
      // reconnecting): nothing of ours left to write.
      bridgeFatal = true
      remoteEnded(reason: .remoteEnded)
    case "not_found", "bad_request":
      bridgeFatal = true
      endWithWrite(reason: .failed)
    default:
      // busy, internal and anything unknown (protocol.go: treat as internal):
      // the socket closes next and that is retried.
      return
    }
  }

  func bridgeClosed(_ client: BridgeClient) {
    guard client === bridge, call != nil else { return }
    bridge = nil
    uplink.value = nil
    if bridgeFatal { return }

    let deadline = reconnectDeadline ?? Date().addingTimeInterval(Config.reconnectWindow)
    reconnectDeadline = deadline
    guard Date() < deadline else {
      Log.error("bridge did not come back within \(Int(Config.reconnectWindow))s")
      lastError = "Связь потеряна"
      endWithWrite(reason: .failed)
      return
    }
    if phase == .inCall { phase = .reconnecting }
    let uuid = call?.uuid
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      guard self.call?.uuid == uuid, self.bridge == nil else { return }
      self.openBridge()
    }
  }
}

// MARK: - CXProviderDelegate

extension CallController: CXProviderDelegate {
  nonisolated func providerDidReset(_ provider: CXProvider) {
    MainActor.assumeIsolated {
      self.pendingOutgoing = nil
      self.finishLocally()
    }
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    MainActor.assumeIsolated { self.performStart(action) }
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    MainActor.assumeIsolated { self.performAnswer(action) }
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    MainActor.assumeIsolated { self.performEnd(action) }
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    MainActor.assumeIsolated { self.performSetMuted(action) }
  }

  nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    MainActor.assumeIsolated { self.audioActivated() }
  }

  nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    MainActor.assumeIsolated { self.audio.stop() }
  }
}

// MARK: - PKPushRegistryDelegate

extension CallController: PKPushRegistryDelegate {
  nonisolated func pushRegistry(
    _ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    MainActor.assumeIsolated {
      self.voipToken = token
      self.registerDevice()
    }
  }

  nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    MainActor.assumeIsolated {
      self.voipToken = nil
      self.pushRegistered = false
    }
  }

  nonisolated func pushRegistry(
    _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType, completion: @escaping @Sendable () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    let dict = payload.dictionaryPayload
    MainActor.assumeIsolated { self.handlePush(dict, completion: completion) }
  }
}

/// A value shared with a non-main thread.
final class Locked<T> {
  private let lock = NSLock()
  private var _value: T

  init(_ value: T) { _value = value }

  var value: T {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _value
    }
    set {
      lock.lock()
      _value = newValue
      lock.unlock()
    }
  }
}
