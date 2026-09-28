import Flutter
import UIKit
import CallKit
import AVFoundation
import UserNotifications

@available(iOS 10.0, *)
public class SwiftFlutterCallkitIncomingPlugin: NSObject, FlutterPlugin, CXProviderDelegate {
    
    static let ACTION_DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP = "com.hiennv.flutter_callkit_incoming.DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP"
    
    static let ACTION_CALL_INCOMING = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_INCOMING"
    static let ACTION_CALL_START = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_START"
    static let ACTION_CALL_ACCEPT = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_ACCEPT"
    static let ACTION_CALL_DECLINE = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_DECLINE"
    static let ACTION_CALL_ENDED = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_ENDED"
    static let ACTION_CALL_TIMEOUT = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TIMEOUT"
    static let ACTION_CALL_CALLBACK = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_CALLBACK"
    static let ACTION_CALL_CUSTOM = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_CUSTOM"
    static let ACTION_CALL_CONNECTED = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_CONNECTED"
    
    static let ACTION_CALL_PROVIDER_DID_RESET = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_PROVIDER_DID_RESET"
    
    static let ACTION_CALL_TOGGLE_HOLD = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_HOLD"
    static let ACTION_CALL_TOGGLE_MUTE = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_MUTE"
    static let ACTION_CALL_TOGGLE_DMTF = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_DMTF"
    static let ACTION_CALL_TOGGLE_GROUP = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_GROUP"
    static let ACTION_CALL_TOGGLE_AUDIO_SESSION = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_AUDIO_SESSION"
    
    @objc public private(set) static var sharedInstance: SwiftFlutterCallkitIncomingPlugin!
    
    private var streamHandlers: WeakArray<EventCallbackHandler> = WeakArray([])
    
    private var callManager: CallManager
    
    private var sharedProvider: CXProvider? = nil
    
    private var outgoingCall : Call?
    private var answerCall : Call?
    
    private var data: Data?
    private var isFromPushKit: Bool = false
    private var silenceEvents: Bool = false
    private let devicePushTokenVoIP = "DevicePushTokenVoIP"

    
    /// The event payload for a call known only by uuid: the full stored data
    /// when it is that call, otherwise just the id — enough for Dart to route
    /// the event, and never another call's identity.
    private func eventBody(for uuid: UUID) -> [String: Any?] {
        if let stored = self.data, stored.uuid.lowercased() == uuid.uuidString.lowercased() {
            return stored.toJSON()
        }
        return ["id": uuid.uuidString.lowercased()]
    }

    private func sendEvent(_ event: String, _ body: [String : Any?]?) {
        if silenceEvents {
            print(event, " silenced")
            return
        } else {
            streamHandlers.reap().forEach { handler in
                handler?.send(event, body ?? [:])
            }
        }
        
    }
    
    @objc public func sendEventCustom(_ event: String, body: NSDictionary?) {
        streamHandlers.reap().forEach { handler in
            handler?.send(event, body ?? [:])
        }
    }
    
    public static func sharePluginWithRegister(with registrar: FlutterPluginRegistrar) {
        if(sharedInstance == nil){
            sharedInstance = SwiftFlutterCallkitIncomingPlugin(messenger: registrar.messenger())
        }
        sharedInstance.shareHandlers(with: registrar)
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        sharePluginWithRegister(with: registrar)
    }
    
    private static func createMethodChannel(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
        return FlutterMethodChannel(name: "flutter_callkit_incoming", binaryMessenger: messenger)
    }
    
    private static func createEventChannel(messenger: FlutterBinaryMessenger) -> FlutterEventChannel {
        return FlutterEventChannel(name: "flutter_callkit_incoming_events", binaryMessenger: messenger)
    }
    
    public init(messenger: FlutterBinaryMessenger) {
        callManager = CallManager()
    }
    
    private func shareHandlers(with registrar: FlutterPluginRegistrar) {
        registrar.addMethodCallDelegate(self, channel: Self.createMethodChannel(messenger: registrar.messenger()))
        let eventsHandler = EventCallbackHandler()
        self.streamHandlers.append(eventsHandler)
        Self.createEventChannel(messenger: registrar.messenger()).setStreamHandler(eventsHandler)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "showCallkitIncoming":
            guard let args = call.arguments else {
                result(true)
                return
            }
            if let getArgs = args as? [String: Any] {
                // Not stored here: showCallkitIncoming adopts it as self.data
                // only once CallKit has accepted the report. Storing it up
                // front meant a ring iOS REJECTED (one is already live) still
                // replaced the live call's data — its audio-session mode and
                // the identity every id-less event is sent under.
                showCallkitIncoming(Data(args: getArgs), fromPushKit: false)
            }
            result(true)
            break
        case "showMissCallNotification":
            guard let args = call.arguments else {
                result(true)
                return
            }
            if let getArgs = args as? [String: Any] {
                self.data = Data(args: getArgs)
                self.showMissedCallNotification(data!)
            }
            result(true)
            break
        case "startCall":
            guard let args = call.arguments else {
                result(true)
                return
            }
            if let getArgs = args as? [String: Any] {
                self.data = Data(args: getArgs)
                self.startCall(self.data!, fromPushKit: false)
            }
            result(true)
            break
        case "endCall":
            // Always end the call the caller NAMED. The old isFromPushKit branch
            // discarded the argument and ended self.data (the PushKit ring), so
            // ending a stale call while answering ended the answered call instead.
            if let getArgs = call.arguments as? [String: Any] {
                self.endCall(Data(args: getArgs))
            } else if let stored = self.data {
                self.endCall(stored)
            }
            result(true)
            break
        case "muteCall":
            guard let args = call.arguments as? [String: Any] ,
                  let callId = args["id"] as? String,
                  let isMuted = args["isMuted"] as? Bool else {
                result(true)
                return
            }
            
            self.muteCall(callId, isMuted: isMuted)
            result(true)
            break
        case "isMuted":
            guard let args = call.arguments as? [String: Any] ,
                  let callId = args["id"] as? String else{
                result(false)
                return
            }
            guard let callUUID = UUID(uuidString: callId),
                  let call = self.callManager.callWithUUID(uuid: callUUID) else {
                result(false)
                return
            }
            result(call.isMuted)
            break
        case "holdCall":
            guard let args = call.arguments as? [String: Any] ,
                  let callId = args["id"] as? String,
                  let onHold = args["isOnHold"] as? Bool else {
                result(true)
                return
            }
            self.holdCall(callId, onHold: onHold)
            result(true)
            break
        case "callConnected":
            guard let args = call.arguments else {
                result(true)
                return
            }
            // Always connect the call the caller NAMED — the same fix endCall
            // got. The old isFromPushKit branch threw the argument away and
            // connected self.data (whatever PushKit reported last), and the
            // other branch replaced self.data with an id-only stub, wiping the
            // live call's audio-session settings.
            if let getArgs = args as? [String: Any] {
                self.connectedCall(Data(args: getArgs))
            } else if let stored = self.data {
                self.connectedCall(stored)
            }
            result(true)
            break
        case "activeCalls":
            result(self.callManager.activeCalls())
            break;
        case "endAllCalls":
            self.callManager.endCallAlls()
            result(true)
            break
        case "getDevicePushTokenVoIP":
            result(self.getDevicePushTokenVoIP())
            break;
        case "silenceEvents":
            guard let silence = call.arguments as? Bool else {
                result(true)
                return
            }
            
            self.silenceEvents = silence
            result(true)
            break;
        case "requestNotificationPermission":
            guard let args = call.arguments else {
                result(true)
                return
            }
            if let getArgs = args as? [String: Any] {
                self.requestNotificationPermission(getArgs)
            }
            result(true)
            break
         case "requestFullIntentPermission": 
            result(true)
            break
         case "canUseFullScreenIntent": 
            result(true)
            break
        case "hideCallkitIncoming":
            result(true)
            break
        case "endNativeSubsystemOnly":
            result(true)
            break
        case "setAudioRoute":
            result(true)
            break
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    @objc public func setDevicePushTokenVoIP(_ deviceToken: String) {
        UserDefaults.standard.set(deviceToken, forKey: devicePushTokenVoIP)
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP, ["deviceTokenVoIP":deviceToken])
    }
    
    @objc public func getDevicePushTokenVoIP() -> String {
        return UserDefaults.standard.string(forKey: devicePushTokenVoIP) ?? ""
    }
    
    @objc public func getAcceptedCall() -> Data? {
        NSLog("Call data ids \(String(describing: data?.uuid)) \(String(describing: answerCall?.uuid.uuidString))")
        if data?.uuid.lowercased() == answerCall?.uuid.uuidString.lowercased() {
            return data
        }
        return nil
    }
    
    @objc public func showCallkitIncoming(_ data: Data, fromPushKit: Bool, onError: ((Error?) -> Void)? = nil) {
        // isFromPushKit / self.data are adopted in the SUCCESS completion
        // below, never here: a report iOS rejects (a call is already live and
        // maximumCallsPerCallGroup is 1, Do Not Disturb, a duplicate uuid)
        // must leave the live call's stored data and flag exactly as they were.
        if(data.isShowMissedCallNotification){
            CallkitNotificationManager.shared.addNotificationCategory(data.missedNotificationCallbackText)
        }
        
        var handle: CXHandle?
        handle = CXHandle(type: self.getHandleType(data.handleType), value: data.getEncryptHandle())
        
        let callUpdate = CXCallUpdate()

        callUpdate.remoteHandle = handle
        callUpdate.supportsDTMF = data.supportsDTMF
        callUpdate.supportsHolding = data.supportsHolding
        callUpdate.supportsGrouping = data.supportsGrouping
        callUpdate.supportsUngrouping = data.supportsUngrouping
        callUpdate.hasVideo = data.type > 0 ? true : false
        callUpdate.localizedCallerName = data.nameCaller
        
        initCallkitProvider(data)
        
        // Guard against malformed UUID — see CallManager.swift:startCall for rationale.
        guard let uuid = UUID(uuidString: data.uuid) else {
            NSLog("[CallkitIncoming] showIncomingCall(no PushKit): invalid UUID '\(data.uuid)' — ignored")
            return
        }
        
        // Do NOT configure the audio session before reportNewIncomingCall.
        // When maximumCallsPerCallGroup == 1 and a call is already active, iOS
        // rejects the new call (error != nil). Re-activating the shared
        // AVAudioSession up front would, in that rejected case, still interrupt
        // the active call's audio (e.g. WebRTC breakage). Configure it only once
        // the call is successfully reported, matching the fromPushKit variant.
        self.sharedProvider?.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if(error == nil) {
                self.isFromPushKit = fromPushKit
                self.data = data
                self.configureAudioSession()
                let call = Call(uuid: uuid, data: data)
                call.handle = data.handle
                self.callManager.addCall(call)
                self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_INCOMING, data.toJSON())
                self.endCallNotExist(data)
            } else {
                onError?(error)
            }
        }
    }
    
    @objc public func showCallkitIncoming(_ data: Data, fromPushKit: Bool) {
        self.showCallkitIncoming(data, fromPushKit: fromPushKit, onError: nil)
    }
    
    @objc public func showCallkitIncoming(_ data: Data, fromPushKit: Bool, completion: @escaping () -> Void) {
        // isFromPushKit / self.data are adopted in the SUCCESS completion
        // below, never here: a report iOS rejects (a call is already live and
        // maximumCallsPerCallGroup is 1, Do Not Disturb, a duplicate uuid)
        // must leave the live call's stored data and flag exactly as they were.
        if(data.isShowMissedCallNotification){
            CallkitNotificationManager.shared.addNotificationCategory(data.missedNotificationCallbackText)
        }
        
        var handle: CXHandle?
        handle = CXHandle(type: self.getHandleType(data.handleType), value: data.getEncryptHandle())
        
        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = handle
        callUpdate.supportsDTMF = data.supportsDTMF
        callUpdate.supportsHolding = data.supportsHolding
        callUpdate.supportsGrouping = data.supportsGrouping
        callUpdate.supportsUngrouping = data.supportsUngrouping
        callUpdate.hasVideo = data.type > 0 ? true : false
        callUpdate.localizedCallerName = data.nameCaller
        
        initCallkitProvider(data)
        
        // Guard against malformed UUID — see CallManager.swift:startCall for rationale.
        // PushKit call MUST report within ~5s deadline; on invalid UUID we still call
        // completion() so iOS doesn't penalize the app for the missed deadline.
        guard let uuid = UUID(uuidString: data.uuid) else {
            NSLog("[CallkitIncoming] showCallkitIncoming: invalid UUID '\(data.uuid)' — ignored")
            completion()
            return
        }
        
        self.sharedProvider?.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if(error == nil) {
                self.isFromPushKit = fromPushKit
                self.data = data
                self.configureAudioSession()
                let call = Call(uuid: uuid, data: data)
                call.handle = data.handle
                self.callManager.addCall(call)
                self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_INCOMING, data.toJSON())
                self.endCallNotExist(data)
            }
            completion()
        }
    }
    
    
    // MARK: - Host-app PushKit helpers (cancel pushes, garbage pushes)

    /// The shared instance, created on the spot if Flutter has not registered
    /// the plugin yet.
    ///
    /// A VoIP push can launch the app in the background before any Flutter
    /// engine exists, and `sharedInstance` used to be born only inside
    /// `register(with:)`. The host's PushKit handler reached it through
    /// optional chaining, so on that launch nothing was reported to CallKit and
    /// PushKit's completion was never called — iOS kills the app for that
    /// (0xbaadca11) and, after a few, stops delivering VoIP pushes at all.
    ///
    /// Creating it early is safe because `init` does nothing but build a
    /// CallManager (the messenger argument was never used), and
    /// `sharePluginWithRegister` already copes with an instance that exists
    /// before registration: it only attaches the channels. Events sent before
    /// that have no listener and are dropped, which the Dart side already
    /// expects — a cold-started engine learns about the ring, and whether it
    /// was answered, from activeCalls().
    @objc public static func ensureSharedInstance() -> SwiftFlutterCallkitIncomingPlugin {
        if sharedInstance == nil {
            sharedInstance = SwiftFlutterCallkitIncomingPlugin(detached: true)
        }
        return sharedInstance
    }

    /// An instance with no Flutter engine behind it yet (see above).
    private init(detached: Bool) {
        callManager = CallManager()
        super.init()
    }

    /// Whether CallKit (or this plugin) currently holds a call with this uuid.
    @objc public func isCallActive(uuidString: String) -> Bool {
        guard let uuid = UUID(uuidString: uuidString) else { return false }
        if let call = self.callManager.callWithUUID(uuid: uuid), !call.hasEnded {
            return true
        }
        return self.callManager.isKnownToSystem(uuid: uuid)
    }

    /// The provider to report on, WITHOUT touching a live one's configuration.
    ///
    /// initCallkitProvider reassigns `configuration` on every report, and doing
    /// that for a throwaway report while a call is live is what reset the live
    /// call's limits (maximumCallGroups back to the default 2 — hence the
    /// call-waiting flash). Only when there is no provider at all is one made,
    /// with the strictest limits: one group, one call, so a throwaway report
    /// made during a live call is refused by iOS instead of shown.
    private func providerForThrowawayReport(appName: String) -> CXProvider {
        if let provider = self.sharedProvider { return provider }
        let configuration = CXProviderConfiguration(localizedName: appName)
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic, .emailAddress, .phoneNumber]
        let provider = CXProvider(configuration: configuration)
        provider.setDelegate(self, queue: nil)
        self.sharedProvider = provider
        self.callManager.setSharedProvider(provider)
        return provider
    }

    /// For a VoIP push that must NOT ring: a cancel (the caller hung up before
    /// we answered) or a push whose call id is garbage.
    ///
    /// Apple requires every VoIP push to report an incoming call before the
    /// PushKit completion runs, so one is reported under `uuid` and ended from
    /// inside the report's own completion handler — by which point CallKit
    /// definitely knows (or has definitely refused) the uuid. The old cancel
    /// path ended it with a CXEndCallAction fired right after the report was
    /// *requested*; when that overtook the report, CallKit answered "unknown
    /// uuid", the end was lost, and a nameless call rang out its full timeout.
    ///
    /// When `uuid` is a ring already on screen, the report fails with
    /// callUUIDAlreadyExists — no second ring, nothing shown — and the
    /// reportCall(endedAt:) that follows dismisses the real ring. So a cancel
    /// for a showing ring and a cancel for a ring that never arrived are the
    /// same code path, and the push is accounted for in both.
    ///
    /// Deliberately NOT done here, all of which the old path did via
    /// showCallkitIncoming: replacing self.data / isFromPushKit (they belong to
    /// the live call), reconfiguring the provider, configuring the audio
    /// session (setMode(.default) under a live call), registering the call
    /// with the CallManager, arming a ring timeout.
    ///
    /// Ending through reportCall(endedAt:reason:) rather than a CXEndCallAction
    /// also matters to Dart: an end *action* is what a local hang-up looks
    /// like, and came back as ACTION_CALL_DECLINE — the app then recorded a
    /// decline by the user for a call the CALLER had cancelled.
    ///
    /// `completion` is always called, exactly once, on the provider's queue
    /// (main).
    @objc public func reportAndEndCall(
        uuid: UUID,
        callerName: String,
        appName: String,
        reason: CXCallEndedReason,
        completion: @escaping () -> Void
    ) {
        let wasActive = self.isCallActive(uuidString: uuid.uuidString)
        let provider = self.providerForThrowawayReport(appName: appName)

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsDTMF = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        provider.reportNewIncomingCall(with: uuid, update: update) { _ in
            // Whatever the report's outcome: accepted (end the throwaway call
            // before it is heard), already-exists (end the real ring), or
            // refused (ending an unknown uuid is a no-op).
            provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
            if wasActive {
                self.forgetRemotelyEndedCall(uuid)
            }
            completion()
        }
    }

    /// End a call the REMOTE side ended, if CallKit has it. Returns whether
    /// there was one. No CXEndCallAction is involved, so no ACTION_CALL_DECLINE
    /// — Dart gets ACTION_CALL_ENDED with `extra.remoteEnded == true`.
    @discardableResult
    @objc public func reportRemoteEnded(uuidString: String) -> Bool {
        guard let uuid = UUID(uuidString: uuidString),
              self.isCallActive(uuidString: uuidString),
              let provider = self.sharedProvider else {
            return false
        }
        provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        self.forgetRemotelyEndedCall(uuid)
        return true
    }

    /// Book-keeping for a call ended by reportCall(endedAt:) — CallKit sends no
    /// delegate callback for those, so what the CXEndCallAction handler does
    /// for a local end has to be done by hand: drop it from the manager (which
    /// also disarms its endCallNotExist ring timeout), release the
    /// answered/outgoing slot if it held one, and tell Dart.
    private func forgetRemotelyEndedCall(_ uuid: UUID) {
        var body = self.eventBody(for: uuid)
        if let call = self.callManager.callWithUUID(uuid: uuid) {
            body = call.data.toJSON()
            call.endCall()
            self.callManager.removeCall(call)
        }
        if self.answerCall?.uuid == uuid { self.answerCall = nil }
        if self.outgoingCall?.uuid == uuid { self.outgoingCall = nil }
        if self.isFromPushKit, let stored = self.data,
           stored.uuid.lowercased() == uuid.uuidString.lowercased() {
            self.isFromPushKit = false
        }
        // ENDED, never DECLINE: nobody on this phone declined anything. The
        // marker lets Dart tell a remote end from the user's own red button,
        // which arrive under the same event name.
        var extra: [String: Any] = [:]
        if let existing = body["extra"] as? NSDictionary {
            for (key, value) in existing {
                if let key = key as? String { extra[key] = value }
            }
        }
        extra["remoteEnded"] = true
        body["extra"] = extra
        sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ENDED, body)
    }

    @objc public func startCall(_ data: Data, fromPushKit: Bool) {
        self.isFromPushKit = fromPushKit
        if(fromPushKit){
            self.data = data
        }
        initCallkitProvider(data)
        self.callManager.startCall(data)
    }
    
    @objc public func muteCall(_ callId: String, isMuted: Bool) {
        guard let callId = UUID(uuidString: callId),
              let call = self.callManager.callWithUUID(uuid: callId) else {
            return
        }
        if call.isMuted == isMuted {
            self.sendMuteEvent(callId.uuidString, isMuted)
        } else {
            self.callManager.muteCall(call: call, isMuted: isMuted)
        }
    }
    
    @objc public func holdCall(_ callId: String, onHold: Bool) {
        guard let callId = UUID(uuidString: callId),
              let call = self.callManager.callWithUUID(uuid: callId) else {
            return
        }
        if call.isOnHold == onHold {
            self.sendHoldEvent(callId.uuidString, onHold)
        } else {
            self.callManager.holdCall(call: call, onHold: onHold)
        }
    }
    
    @objc public func endCall(_ data: Data) {
        // Ends exactly the call in `data`. The old version redirected to
        // self.data whenever isFromPushKit was set, which made every
        // programmatic end target the PushKit ring regardless of the argument.
        guard let uuid = UUID(uuidString: data.uuid) else {
            NSLog("[CallkitIncoming] endCall: invalid UUID '\(data.uuid)' — ignored")
            return
        }
        if self.isFromPushKit, let stored = self.data,
           stored.uuid.lowercased() == data.uuid.lowercased() {
            // Ending the PushKit-reported ring itself: clear the flag so the
            // stored ring stops standing in for later calls. No event here —
            // the CXEndCallAction handler below names this call in both of its
            // branches (including the one for a call the manager has already
            // forgotten), so sending one here too meant two events per end and
            // Dart's single-shot echo swallow only ever caught the first.
            self.isFromPushKit = false
        }
        let call = Call(uuid: uuid, data: data)
        self.callManager.endCall(call: call)
    }
    
    @objc public func connectedCall(_ data: Data) {
        // Connects exactly the call in `data`, like endCall. The old version
        // redirected to self.data whenever isFromPushKit was set — and that
        // flag used to be set even by a PushKit report iOS rejected — so
        // connecting the live call could answer a different uuid instead.
        // Guard against malformed UUID — see CallManager.swift:startCall for rationale.
        guard let uuid = UUID(uuidString: data.uuid) else {
            NSLog("[CallkitIncoming] connectedCall: invalid UUID '\(data.uuid)' — ignored")
            return
        }
        if self.isFromPushKit, let stored = self.data,
           stored.uuid.lowercased() == data.uuid.lowercased() {
            self.isFromPushKit = false
        }
        let call = Call(uuid: uuid, data: data)
        self.callManager.connectedCall(call: call)
    }
    
    @objc public func activeCalls() -> [[String: Any]] {
        return self.callManager.activeCalls()
    }
    
    @objc public func endAllCalls() {
        self.isFromPushKit = false
        self.callManager.endCallAlls()
    }
    
    public func saveEndCall(_ uuid: String, _ reason: Int) {
        // Guard against malformed UUID — see CallManager.swift:startCall for rationale.
        // Single guard at top covers all five branches.
        guard let callUuid = UUID(uuidString: uuid) else {
            NSLog("[CallkitIncoming] saveEndCall: invalid UUID '\(uuid)' (reason=\(reason)) — ignored")
            return
        }
        switch reason {
        case 1:
            self.sharedProvider?.reportCall(with: callUuid, endedAt: Date(), reason: CXCallEndedReason.failed)
            break
        case 2, 6:
            self.sharedProvider?.reportCall(with: callUuid, endedAt: Date(), reason: CXCallEndedReason.remoteEnded)
            break
        case 3:
            self.sharedProvider?.reportCall(with: callUuid, endedAt: Date(), reason: CXCallEndedReason.unanswered)
            break
        case 4:
            self.sharedProvider?.reportCall(with: callUuid, endedAt: Date(), reason: CXCallEndedReason.answeredElsewhere)
            break
        case 5:
            self.sharedProvider?.reportCall(with: callUuid, endedAt: Date(), reason: CXCallEndedReason.declinedElsewhere)
            break
        default:
            break
        }
    }
    
    
    func endCallNotExist(_ data: Data) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(data.duration)) {
            // Guard against malformed UUID — see CallManager.swift:startCall for rationale.
            guard let uuid = UUID(uuidString: data.uuid) else {
                NSLog("[CallkitIncoming] endCallNotExist: invalid UUID '\(data.uuid)' — ignored")
                return
            }
            let call = self.callManager.callWithUUID(uuid: uuid)
            // Per-call, not global: this timer belongs to THIS ring, so the
            // only thing that may cancel it is THIS ring having been answered
            // or dialled. Testing "is any call live" instead let one call's
            // timer end a different, live call.
            let isLive = self.answerCall?.uuid == uuid || self.outgoingCall?.uuid == uuid
            if (call != nil && !isLive) {
                self.callEndTimeout(data)
            }
        }
    }
    
    
    
    func callEndTimeout(_ data: Data) {
        self.saveEndCall(data.uuid, 3)
        // Guard against malformed UUID — see CallManager.swift:startCall for rationale.
        guard let uuid = UUID(uuidString: data.uuid) else {
            NSLog("[CallkitIncoming] callEndTimeout: invalid UUID '\(data.uuid)' — ignored")
            return
        }
        guard let call = self.callManager.callWithUUID(uuid: uuid) else {
            return
        }
        self.showMissedCallNotification(data)
        sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TIMEOUT, data.toJSON())
        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.onTimeOut(call)
        }
    }
    
    func getHandleType(_ handleType: String?) -> CXHandle.HandleType {
        var typeDefault = CXHandle.HandleType.generic
        switch handleType {
        case "number":
            typeDefault = CXHandle.HandleType.phoneNumber
            break
        case "email":
            typeDefault = CXHandle.HandleType.emailAddress
        default:
            typeDefault = CXHandle.HandleType.generic
        }
        return typeDefault
    }
    
    func initCallkitProvider(_ data: Data) {
        if(self.sharedProvider == nil){
            self.sharedProvider = CXProvider(configuration: createConfiguration(data))
            self.sharedProvider?.setDelegate(self, queue: nil)
        } else {
            self.sharedProvider?.configuration = createConfiguration(data)
        }
        self.callManager.setSharedProvider(self.sharedProvider!)
    }
    
    func createConfiguration(_ data: Data) -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration(localizedName: data.appName)
        configuration.supportsVideo = data.supportsVideo
        configuration.maximumCallGroups = data.maximumCallGroups
        configuration.maximumCallsPerCallGroup = data.maximumCallsPerCallGroup
        
        configuration.supportedHandleTypes = [
            CXHandle.HandleType.generic,
            CXHandle.HandleType.emailAddress,
            CXHandle.HandleType.phoneNumber
        ]
        if #available(iOS 11.0, *) {
            configuration.includesCallsInRecents = data.includesCallsInRecents
        }
        if !data.iconName.isEmpty {
            if let image = UIImage(named: data.iconName) {
                configuration.iconTemplateImageData = image.pngData()
            } else {
                print("Unable to load icon \(data.iconName).");
            }
        }
        if !data.ringtonePath.isEmpty || data.ringtonePath != "system_ringtone_default"  {
            configuration.ringtoneSound = data.ringtonePath
        }
        return configuration
    }
    
    func sendDefaultAudioInterruptionNotificationToStartAudioResource(){
        var userInfo : [AnyHashable : Any] = [:]
        let intrepEndeRaw = AVAudioSession.InterruptionType.ended.rawValue
        userInfo[AVAudioSessionInterruptionTypeKey] = intrepEndeRaw
        userInfo[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: self, userInfo: userInfo)
    }
    
    func configureAudioSession(){
        if data?.configureAudioSession != false {
            let session = AVAudioSession.sharedInstance()
            do{
                try session.setCategory(AVAudioSession.Category.playAndRecord, options: [
                    .allowBluetoothA2DP,
                    .duckOthers,
                    .allowBluetooth,
                ])
                
                try session.setMode(self.getAudioSessionMode(data?.audioSessionMode))
                try session.setActive(data?.audioSessionActive ?? true)
                try session.setPreferredSampleRate(data?.audioSessionPreferredSampleRate ?? 44100.0)
                try session.setPreferredIOBufferDuration(data?.audioSessionPreferredIOBufferDuration ?? 0.005)
            }catch{
                print(error)
            }
        }
    }
    
    func getAudioSessionMode(_ audioSessionMode: String?) -> AVAudioSession.Mode {
        var mode = AVAudioSession.Mode.default
        switch audioSessionMode {
        case "gameChat":
            mode = AVAudioSession.Mode.gameChat
            break
        case "measurement":
            mode = AVAudioSession.Mode.measurement
            break
        case "moviePlayback":
            mode = AVAudioSession.Mode.moviePlayback
            break
        case "spokenAudio":
            mode = AVAudioSession.Mode.spokenAudio
            break
        case "videoChat":
            mode = AVAudioSession.Mode.videoChat
            break
        case "videoRecording":
            mode = AVAudioSession.Mode.videoRecording
            break
        case "voiceChat":
            mode = AVAudioSession.Mode.voiceChat
            break
        case "voicePrompt":
            if #available(iOS 12.0, *) {
                mode = AVAudioSession.Mode.voicePrompt
            } else {
                // Fallback on earlier versions
            }
            break
        default:
            mode = AVAudioSession.Mode.default
        }
        return mode
    }
    
    public func providerDidReset(_ provider: CXProvider) {
        for call in self.callManager.calls {
            call.endCall()
        }
        self.callManager.removeAllCalls()
        sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_PROVIDER_DID_RESET, [:])
        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.providerDidReset()
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let call = Call(uuid: action.callUUID, data: self.data!, isOutGoing: true)
        call.handle = action.handle.value
        configureAudioSession()
        call.hasStartedConnectDidChange = { [weak self] in
            self?.sharedProvider?.reportOutgoingCall(with: call.uuid, startedConnectingAt: call.connectData)
        }
        call.hasConnectDidChange = { [weak self] in
            self?.sharedProvider?.reportOutgoingCall(with: call.uuid, connectedAt: call.connectedData)
        }
        self.outgoingCall = call;
        self.callManager.addCall(call)
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_START, self.data?.toJSON())
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else{
            action.fail()
            return
        }
        self.configureAudioSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1200)) {
            self.configureAudioSession()
        }


        call.hasConnectDidChange = { [weak self] in
            self?.sharedProvider?.reportOutgoingCall(with: call.uuid, connectedAt: call.connectedData)
        }
        call.data.isAccepted = true
        self.answerCall = call
        sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ACCEPT, call.data.toJSON())
        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.onAccept(call, action)
        }else {
            action.fulfill()
        }
    }
    
//    private func checkUnlockedAndFulfill(action: CXAnswerCallAction, counter: Int) {
//        if UIApplication.shared.isProtectedDataAvailable {
//            action.fulfill()
//        } else if counter > 180 { // fail if waiting for more then 3 minutes
//            action.fail()
//        } else {
//            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
//                self.checkUnlockedAndFulfill(action: action, counter: counter + 1)
//            }
//        }
//    }
    
    
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else {
            // The call is not in the manager. This happens when:
            //   1. iOS relaunched the (killed) app just to deliver this end action, or
            //   2. a programmatic endCall raced with the user-initiated CXEndCallAction
            //      that already removed the call.
            // The user actively ended/declined the call, so report DECLINE (not
            // TIMEOUT) so the app can notify its backend and stop ringing elsewhere.
            // Fulfill (not fail) the action: failing a legitimate end action leaves
            // a stale call in the system UI.
            // The event must name the call this action is FOR. self.data is
            // whatever call was reported last (usually the live one), so using
            // it here told Dart the wrong call ended — and ending a stale call
            // during an answer read as "the live call ended".
            if(self.answerCall == nil && self.outgoingCall == nil){
                sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_DECLINE, self.eventBody(for: action.callUUID))
            } else {
                sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ENDED, self.eventBody(for: action.callUUID))
            }
            action.fulfill()
            return
        }
        call.endCall()
        self.callManager.removeCall(call)
        if (self.answerCall == nil && self.outgoingCall == nil) {
            sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_DECLINE, call.data.toJSON())
            if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
                appDelegate.onDecline(call, action)
            } else {
                action.fulfill()
            }
        }else {
            // Only the call that actually ended loses its identity. Clearing
            // `answerCall` for whatever ended meant that sweeping a stale call
            // while another was answered disarmed the answered call's own
            // guard in endCallNotExist, which then reported the LIVE call
            // unanswered 45s in and took the audio session down with it.
            // `outgoingCall` was never cleared at all, which left that guard
            // permanently disarmed once this process had dialled once.
            if self.answerCall?.uuid == call.uuid { self.answerCall = nil }
            if self.outgoingCall?.uuid == call.uuid { self.outgoingCall = nil }
            sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ENDED, call.data.toJSON())
            if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
                appDelegate.onEnd(call, action)
            } else {
                action.fulfill()
            }
        }
    }
    
    
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else {
            action.fail()
            return
        }
        call.isOnHold = action.isOnHold
        call.isMuted = action.isOnHold
        self.callManager.setHold(call: call, onHold: action.isOnHold)
        sendHoldEvent(action.callUUID.uuidString, action.isOnHold)
        if !action.isOnHold {
            sendDefaultAudioInterruptionNotificationToStartAudioResource()
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else {
            action.fail()
            return
        }
        call.isMuted = action.isMuted
        sendMuteEvent(action.callUUID.uuidString, action.isMuted)
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        guard (self.callManager.callWithUUID(uuid: action.callUUID)) != nil else {
            action.fail()
            return
        }
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_GROUP, [ "id": action.callUUID.uuidString, "callUUIDToGroupWith" : action.callUUIDToGroupWith?.uuidString])
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        guard (self.callManager.callWithUUID(uuid: action.callUUID)) != nil else {
            action.fail()
            return
        }
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_DMTF, [ "id": action.callUUID.uuidString, "digits": action.digits, "type": action.type.rawValue ])
        action.fulfill()
    }
    
    
    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.uuid) else {
            action.fail()
            return
        }
        sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TIMEOUT, self.data?.toJSON())
        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.onTimeOut(call)
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {

        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.didActivateAudioSession(audioSession)
        }

        if(self.answerCall?.hasConnected ?? false){
            sendDefaultAudioInterruptionNotificationToStartAudioResource()
            return
        }
        if(self.outgoingCall?.hasConnected ?? false){
            sendDefaultAudioInterruptionNotificationToStartAudioResource()
            return
        }
        self.outgoingCall?.startCall(withAudioSession: audioSession) {success in
            if success {
                self.callManager.addCall(self.outgoingCall!)
                self.outgoingCall?.startAudio()
            }
        }
        self.answerCall?.ansCall(withAudioSession: audioSession) { success in
            if success{
                self.answerCall?.startAudio()
            }
        }
        sendDefaultAudioInterruptionNotificationToStartAudioResource()
        configureAudioSession()

        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_AUDIO_SESSION, [ "isActive": true ])
    }
    
    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        
        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.didDeactivateAudioSession(audioSession)
        }

        if self.outgoingCall?.isOnHold ?? false || self.answerCall?.isOnHold ?? false{
            print("Call is on hold")
            return
        }
        
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_AUDIO_SESSION, [ "isActive": false ])
    }
    
    private func sendMuteEvent(_ id: String, _ isMuted: Bool) {
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_MUTE, [ "id": id, "isMuted": isMuted ])
    }
    
    private func sendHoldEvent(_ id: String, _ isOnHold: Bool) {
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_HOLD, [ "id": id, "isOnHold": isOnHold ])
    }
    
    @objc public func sendCallbackEvent(_ data: [String: Any]?) {
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_CALLBACK, data)
    }
    
    
    private func requestNotificationPermission(_ map: [String: Any]) {
        CallkitNotificationManager.shared.requestNotificationPermission(map)
    }
    
    
    private func showMissedCallNotification(_ data: Data) {
        if(!data.isShowMissedCallNotification){
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = "\(data.nameCaller)"
        content.body = "\(data.missedNotificationSubtitle)"
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = "MISSED_CALL_CATEGORY"
        content.userInfo = data.toJSON()

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)

        let request = UNNotificationRequest(
            identifier: data.uuid,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling missed call notification: \(error)")
            } else {
                print("Missed call notification scheduled.")
            }
        }
    }
    
}

class EventCallbackHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    
    public func send(_ event: String, _ body: Any) {
        let data: [String : Any] = [
            "event": event,
            "body": body
        ]
        eventSink?(data)
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}

@available(iOS 10.0, *)
@objc(FlutterCallkitIncomingPlugin)
public class FlutterCallkitIncomingPlugin: NSObject, FlutterPlugin {
    @objc public static func register(with registrar: FlutterPluginRegistrar) {
        SwiftFlutterCallkitIncomingPlugin.register(with: registrar)
    }
}
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          