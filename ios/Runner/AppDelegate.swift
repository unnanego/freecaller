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
    let isVideo = (payloadDict["video"] as? String) == "true"
    let callData = flutter_callkit_incoming.Data(args: [
      "id": payloadDict["callId"] as? String ?? UUID().uuidString,
      "nameCaller": payloadDict["callerName"] as? String ?? "Звонилка",
      "handle": payloadDict["callerPhone"] as? String ?? "",
      "appName": "Звонилка",
      "type": isVideo ? 1 : 0,
      "duration": 45000,
      "supportsVideo": isVideo,
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
