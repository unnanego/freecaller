import Flutter
import Intents
import UIKit

class SceneDelegate: FlutterSceneDelegate {

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    // Cold launch by Siri: the intent rides in on the connection options.
    for activity in connectionOptions.userActivities {
      handleSiri(activity)
    }
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if handleSiri(userActivity) { return }
    super.scene(scene, continue: userActivity)
  }

  @discardableResult
  private func handleSiri(_ userActivity: NSUserActivity) -> Bool {
    guard let intent = userActivity.interaction?.intent as? INStartCallIntent,
      let uid = intent.contacts?.first?.customIdentifier,
      let appDelegate = UIApplication.shared.delegate as? AppDelegate
    else { return false }
    appDelegate.handleSiriStartCall(
      contactUid: uid, video: intent.callCapability == .videoCall)
    return true
  }
}
