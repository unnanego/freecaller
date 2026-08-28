import AVFAudio
import CallKit
import Flutter
import Intents
import PushKit
import UIKit
import WebRTC
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate,
  PKPushRegistryDelegate, CallkitIncomingAppDelegate
{
  static let appGroupId = "group.com.unnanego.freecaller"
  static let contactsFile = "contacts.json"

  private var intentsChannel: FlutterMethodChannel?
  private var locksChannel: FlutterMethodChannel?
  private var pushRegistry: PKPushRegistry?

  // Siri can launch the app before the Dart listener attaches; buffer the
  // request until Dart signals 'ready'.
  private var dartReady = false
  private var pendingStartCall: [String: Any]?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // WebRTC audio is handed over manually in the CallKit audio-session
    // callbacks below; enabling it earlier is the classic answered-from-
    // lock-screen-but-no-audio bug.
    RTCAudioSession.sharedInstance().useManualAudio = true

    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    pushRegistry = registry

    // Ask once for Siri so «Позвони Аиде через Звонилку» can reach the app.
    INPreferences.requestSiriAuthorization { _ in }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "freecaller/intents",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "syncContacts":
        self?.syncContacts(call.arguments)
        result(nil)
      case "ready":
        self?.dartReady = true
        let pending = self?.pendingStartCall
        self?.pendingStartCall = nil
        result(pending)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    intentsChannel = channel

    // The same channel MainActivity answers on Android. Dart's _applyRoute
    // calls it on every route change and iOS used to have no handler at all,
    // so the reply was MissingPluginException, swallowed in call_locks.dart:
    // the speaker on this platform rested entirely on what the WebRTC plugin
    // asked for, and CallKit hands out a fresh AVAudioSession whose route is
    // decided without reference to it. That is the "speaker turned on before
    // connecting is ignored" report, and why turning it on mid-call worked.
    // Only setSpeaker is handled: acquire/release are Android Wi-Fi/CPU locks
    // and Dart never sends them off Android (CallLocks._invoke gates them).
    //
    // overrideOutputAudioPort is the supported way to move a live call's audio
    // to the speaker, and it has to be applied to the session CallKit actually
    // activated — hence Dart re-applying on audioSessionActivated.
    let locks = FlutterMethodChannel(
      name: "freecaller/call_locks",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    locks.setMethodCallHandler { call, result in
      switch call.method {
      case "setSpeaker":
        let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
        result(AppDelegate.setSpeaker(on))
      case "setKeepScreenOn":
        let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
        // Video calls only (the Dart side decides): a phone left dimming
        // mid-video-call is the whole complaint, while a voice call blanks
        // itself against the ear and must go on doing so.
        UIApplication.shared.isIdleTimerDisabled = on
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    locksChannel = locks
  }

  /// Move call audio to the speaker (or back), returning what happened.
  ///
  /// Same contract as the Android path in MainActivity: a headset the user is
  /// wearing outranks the speaker button (blasting a call out of the
  /// loudspeaker over AirPods is worse than ignoring the toggle), and a route
  /// that is already where it was asked to be is left alone — the override
  /// rebuilds the audio session, audible as a click, and this can be called
  /// repeatedly (every session activation re-applies the desired route).
  ///
  /// The returned string is a debug-log account only. DiagnosticsRepo is
  /// deliberately Android-only (its privacy note explains why), so unlike the
  /// Android path nothing here reaches the server.
  static func setSpeaker(_ on: Bool) -> String {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType }
    let external: Set<AVAudioSession.Port> = [
      .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio,
      .carAudio, .airPlay,
    ]
    let before = AppDelegate.routeDescription()
    if outputs.contains(where: { external.contains($0) }) {
      return "iOS left on external device (\(before))"
    }
    if on == outputs.contains(.builtInSpeaker) {
      return "iOS already \(on ? "on" : "off") speaker (\(before))"
    }
    let session = RTCAudioSession.sharedInstance()
    session.lockForConfiguration()
    defer { session.unlockForConfiguration() }
    do {
      try session.overrideOutputAudioPort(on ? .speaker : .none)
      return "iOS override=\(on ? "speaker" : "none") | before: \(before)"
        + " | after: \(AppDelegate.routeDescription())"
    } catch {
      return "iOS override=\(on ? "speaker" : "none") FAILED: \(error.localizedDescription)"
        + " | route: \(AppDelegate.routeDescription())"
    }
  }

  /// Where the audio actually is, by port type — "builtInSpeaker",
  /// "builtInReceiver" (the earpiece), a headset, and so on.
  static func routeDescription() -> String {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    let names = outputs.map { $0.portType.rawValue }.joined(separator: ", ")
    return names.isEmpty ? "none" : names
  }

  // MARK: - Siri (INStartCallIntent → Dart)

  /// Entry point for both delivery paths (SceneDelegate and, on non-scene
  /// setups, application(_:continue:)).
  func handleSiriStartCall(contactUid: String, video: Bool) {
    let args: [String: Any] = ["contactUid": contactUid, "video": video]
    if dartReady {
      intentsChannel?.invokeMethod("startCall", arguments: args)
    } else {
      pendingStartCall = args
    }
  }

  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if let intent = userActivity.interaction?.intent as? INStartCallIntent,
      let uid = intent.contacts?.first?.customIdentifier
    {
      handleSiriStartCall(contactUid: uid, video: intent.callCapability == .videoCall)
      return true
    }
    return super.application(
      application, continue: userActivity, restorationHandler: restorationHandler)
  }

  /// Writes the roster snapshot into the App Group (read by the Intents
  /// extension's resolveContacts) and teaches Siri the contact names.
  private func syncContacts(_ arguments: Any?) {
    guard let args = arguments as? [String: Any],
      let contacts = args["contacts"] as? [[String: Any]]
    else { return }

    if let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: Self.appGroupId),
      let json = try? JSONSerialization.data(withJSONObject: contacts)
    {
      try? json.write(to: container.appendingPathComponent(Self.contactsFile), options: .atomic)
    }

    // Teach Siri the family names so it recognises «Позвони Аиде». Needs the
    // Siri entitlement (now present); the App Group snapshot above is what the
    // extension reads to resolve the spoken name to a uid.
    let names = contacts.compactMap { $0["displayName"] as? String }.filter { !$0.isEmpty }
    if !names.isEmpty {
      INVocabulary.shared().setVocabularyStrings(NSOrderedSet(array: names), of: .contactName)
    }
  }

  // MARK: - PushKit (VoIP push → CallKit, synchronously)

  func pushRegistry(
    _ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    // Apple requires reporting an incoming call for EVERY VoIP push, in the
    // same run loop, before completion — the app may be terminated and Dart
    // not running. Failure = 0xbaadca11 crash and push throttling.
    let payloadDict = payload.dictionaryPayload
    // Cancel push: the caller hung up before we answered. Apple still requires
    // reporting a call for every VoIP push, so report this id then immediately
    // end it — the ring is dismissed instead of ringing to the 45s timeout.
    if (payloadDict["cancel"] as? String) == "true" {
      let callId = payloadDict["callId"] as? String ?? UUID().uuidString
      let endData = flutter_callkit_incoming.Data(args: [
        "id": callId,
        "nameCaller": "",
        "handle": "",
        "appName": "Звонилка",
        "type": 0,
      ])
      let plugin = SwiftFlutterCallkitIncomingPlugin.sharedInstance
      plugin?.showCallkitIncoming(endData, fromPushKit: true, completion: completion)
      plugin?.endCall(endData)
      return
    }
    let isVideo = (payloadDict["video"] as? String) == "true"
    let callData = flutter_callkit_incoming.Data(args: [
      "id": payloadDict["callId"] as? String ?? UUID().uuidString,
      "nameCaller": payloadDict["callerName"] as? String ?? "Звонилка",
      "handle": payloadDict["callerPhone"] as? String ?? "",
      "appName": "Звонилка",
      // Always report the call as video-capable so iOS foregrounds the app on
      // answer (even from the lock screen) — landing on our in-call screen with
      // the video button instead of the native UI. The real voice/video mode
      // (and audio routing below) still comes from the call doc.
      "type": 1,
      "duration": 45000,
      "supportsVideo": true,
      "maximumCallGroups": 1,
      "supportsDTMF": false,
      "supportsHolding": false,
      "supportsGrouping": false,
      "supportsUngrouping": false,
      "audioSessionMode": isVideo ? "videoChat" : "voiceChat",
    ])
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(
      callData, fromPushKit: true, completion: completion)
  }

  // MARK: - CallkitIncomingAppDelegate (CXProvider forwarding)

  func onAccept(_ call: Call, _ action: CXAnswerCallAction) {
    action.fulfill()
  }

  func onDecline(_ call: Call, _ action: CXEndCallAction) {
    action.fulfill()
  }

  func onEnd(_ call: Call, _ action: CXEndCallAction) {
    action.fulfill()
  }

  func onTimeOut(_ call: Call) {}

  func didActivateAudioSession(_ audioSession: AVAudioSession) {
    // Hand the CallKit-activated session over to WebRTC — the counterpart
    // of useManualAudio in didFinishLaunching.
    let session = RTCAudioSession.sharedInstance()
    session.audioSessionDidActivate(audioSession)
    session.isAudioEnabled = true
  }

  func didDeactivateAudioSession(_ audioSession: AVAudioSession) {
    let session = RTCAudioSession.sharedInstance()
    session.audioSessionDidDeactivate(audioSession)
    session.isAudioEnabled = false
  }

  func providerDidReset() {}
}
