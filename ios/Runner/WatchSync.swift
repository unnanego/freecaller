import Foundation
import UIKit
import WatchConnectivity

/// Hands the signed-in session and the contact list to the Apple Watch app.
///
/// The watch is a calling device of its own (docs/watch-plan.md), but nobody
/// should have to type an emailed code on a watch. So the iPhone, which is
/// already signed in, passes its PocketBase token across once; from then on the
/// watch talks to the server by itself and keeps the session alive with its own
/// authRefresh, with or without this phone nearby.
///
/// The token is read from where Dart keeps it — shared_preferences stores
/// `pbAuth` (lib/data/pb_client.dart) in the standard UserDefaults under the
/// `flutter.` prefix, as `{"token": …, "model": {…}}` — so Dart needs no change
/// and no new channel. Contacts come in through the Siri sync that Dart already
/// does on every roster change (AppDelegate.syncContacts), which is also what
/// sign-out goes through: an empty list there plus a missing token here is the
/// signed-out state, and that is passed on too, so a watch never keeps calling
/// for an account its phone has left.
///
/// updateApplicationContext keeps only the newest dictionary and delivers it
/// whenever the watch app next runs, so pushing on every sync is cheap and a
/// watch that was off just gets the latest state. WatchConnectivity is
/// end-to-end encrypted between the paired devices.
final class WatchSync: NSObject, WCSessionDelegate {
  static let shared = WatchSync()

  /// nil until Dart has synced once this launch. Until then the context goes
  /// out WITHOUT a contacts key, which the watch reads as "keep yours": a token
  /// refresh at launch must not wipe the watch's list before Dart catches up.
  private var lastContacts: [[String: Any]]?

  /// The token in the last context sent ("" = signed out). Dart clears the
  /// contacts BEFORE it clears the session on sign-out (lib/app.dart
  /// _signOut), so the sync that carries the empty list still finds the old
  /// token; the UserDefaults observer below catches the token going away a
  /// moment later and sends the signed-out state then.
  private var lastSentToken: String?

  func activate() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
    // Dart refreshes the PocketBase session on resume; pass the new token on.
    // (A scene-based app gets no app-delegate didBecomeActive, hence the
    // notification.)
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.refresh() }
    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      if (Self.storedAuth()?.token ?? "") != self.lastSentToken { self.send() }
    }
  }

  /// Called with the same list Dart hands to Siri. Safe from any thread.
  func push(contacts: [[String: Any]]) {
    DispatchQueue.main.async {
      self.lastContacts = contacts
      self.send()
    }
  }

  /// Re-send with the current token (the app came to the foreground, and Dart
  /// may have refreshed the session since the last push).
  func refresh() {
    DispatchQueue.main.async { self.send() }
  }

  private func send() {
    let session = WCSession.default
    guard WCSession.isSupported(), session.activationState == .activated,
      session.isPaired, session.isWatchAppInstalled
    else { return }

    var context: [String: Any] = ["v": 1]
    if let auth = Self.storedAuth() {
      context["token"] = auth.token
      context["uid"] = auth.uid
      context["displayName"] = auth.displayName
      if let contacts = lastContacts {
        context["contacts"] = contacts.map { c in
          [
            "uid": c["uid"] as? String ?? "",
            "displayName": c["displayName"] as? String ?? "",
            "phone": c["phone"] as? String ?? "",
          ]
        }
      }
    } else {
      context["signedOut"] = true
    }
    do {
      try session.updateApplicationContext(context)
      lastSentToken = context["token"] as? String ?? ""
    } catch {
      NSLog("[Freecaller] watch sync failed: \(error.localizedDescription)")
    }
  }

  private struct StoredAuth {
    let token: String
    let uid: String
    let displayName: String
  }

  private static func storedAuth() -> StoredAuth? {
    guard let raw = UserDefaults.standard.string(forKey: "flutter.pbAuth"),
      let data = raw.data(using: .utf8),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let token = json["token"] as? String, !token.isEmpty
    else { return nil }
    let model = json["model"] as? [String: Any] ?? [:]
    return StoredAuth(
      token: token,
      uid: model["id"] as? String ?? "",
      displayName: model["displayName"] as? String ?? "")
  }

  // MARK: - WCSessionDelegate

  func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    if activationState == .activated { refresh() }
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}

  func sessionDidDeactivate(_ session: WCSession) {
    // Switching to another paired watch: re-arm for the new one.
    WCSession.default.activate()
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    // The watch app was just installed: give it the session right away.
    refresh()
  }
}
