import Foundation
import Security
import WatchConnectivity

struct Contact: Codable, Identifiable, Hashable {
  let uid: String
  let displayName: String
  let phone: String

  var id: String { uid }

  var initials: String {
    let parts = displayName.split(separator: " ").prefix(2)
    let letters = parts.compactMap { $0.first }.map(String.init).joined()
    return letters.isEmpty ? "?" : letters.uppercased()
  }
}

/// Who is signed in, and whom they can call.
///
/// The session arrives from the iPhone over WatchConnectivity (ios/Runner/
/// WatchSync.swift) — nobody types an emailed code on a watch — and after that
/// lives on the watch: the token in the Keychain, renewed with authRefresh on
/// every launch, so the watch keeps working with its phone switched off or in
/// another country. The contact list is the phone's (the same list it teaches
/// Siri), topped up from the server's roster.
@MainActor
final class AppSession: NSObject, ObservableObject {
  static let shared = AppSession()

  @Published private(set) var token: String?
  @Published private(set) var userId: String = ""
  @Published private(set) var displayName: String = ""
  @Published private(set) var contacts: [Contact] = []

  var isSignedIn: Bool { token != nil && !userId.isEmpty }

  /// This install's identity in the `devices` collection, and what the watch
  /// writes to `answeredOn`. Minted once, kept until the app is deleted.
  let deviceId: String

  /// Fires when the account changes (sign-in, sign-out, different user), so the
  /// push registration can follow.
  var onAccountChanged: (() -> Void)?

  /// Fires just before a signed-in session is dropped, with what is needed to
  /// remove this watch's push registration: (userId, token, deviceId).
  var onWillSignOut: ((String, String, String) -> Void)?

  private let defaults = UserDefaults.standard

  private override init() {
    if let id = UserDefaults.standard.string(forKey: "deviceId") {
      deviceId = id
    } else {
      let id = UUID().uuidString.lowercased()
      UserDefaults.standard.set(id, forKey: "deviceId")
      deviceId = id
    }
    super.init()
  }

  func start() {
    token = Keychain.read()
    userId = defaults.string(forKey: "userId") ?? ""
    displayName = defaults.string(forKey: "displayName") ?? ""
    if let data = defaults.data(forKey: "contacts"),
      let saved = try? JSONDecoder().decode([Contact].self, from: data)
    {
      contacts = saved
    }

    if WCSession.isSupported() {
      WCSession.default.delegate = self
      WCSession.default.activate()
    }

    Task { await refreshFromServer() }
  }

  /// Renew the token and top up the contact list. PocketBase tokens are
  /// stateless and expire (three years here); refreshing on every launch keeps
  /// pushing that out, exactly as the phone app does.
  func refreshFromServer() async {
    guard let token, !userId.isEmpty else { return }
    // The phone can hand over a different session while these requests are on
    // the wire; an answer about the old one must not overwrite the new one.
    let uid = userId
    do {
      let fresh = try await PocketBase.shared.authRefresh(token: token)
      guard self.userId == uid, self.token == token else { return }
      setToken(fresh)
    } catch let error as PBError where error.status == 401 {
      guard self.userId == uid, self.token == token else { return }
      Log.error("session rejected by the server — signing out")
      signOut()
      return
    } catch {
      Log.error("auth refresh failed", error)  // offline: keep the old token
    }
    do {
      let roster = try await PocketBase.shared.fetchRoster(userId: uid, token: self.token ?? token)
      guard self.userId == uid else { return }
      mergeContacts(roster)
    } catch {
      Log.error("roster fetch failed", error)
    }
  }

  /// Any request answered 401: the token is dead and only the phone can mint a
  /// new one.
  func tokenRejected() {
    Log.error("token rejected — signing out until the iPhone sends a new one")
    signOut()
  }

  // MARK: - state changes

  private func apply(context: [String: Any]) {
    if context["signedOut"] as? Bool == true {
      Log.info("iPhone signed out")
      signOut()
      return
    }
    guard let newToken = context["token"] as? String, !newToken.isEmpty,
      let uid = context["uid"] as? String, !uid.isEmpty
    else { return }

    // WatchConnectivity hands back the phone's LAST context on every launch.
    // A token already applied once is not news: re-applying it would replace
    // the fresher one this watch refreshed since — or, if it was rejected,
    // sign back in with a dead token on every launch.
    let sameTokenAsBefore = newToken == defaults.string(forKey: "lastPhoneToken")
    if sameTokenAsBefore && (uid == userId || !isSignedIn) {
      if uid == userId, let raw = context["contacts"] as? [[String: String]] {
        setContacts(Self.contacts(from: raw))
      }
      return
    }
    defaults.set(newToken, forKey: "lastPhoneToken")

    let accountChanged = uid != userId
    if accountChanged, isSignedIn, let token {
      onWillSignOut?(userId, token, deviceId)
    }
    if accountChanged {
      contacts = []
      defaults.removeObject(forKey: "contacts")
    }
    userId = uid
    displayName = context["displayName"] as? String ?? ""
    defaults.set(uid, forKey: "userId")
    defaults.set(displayName, forKey: "displayName")
    setToken(newToken)

    // No key = the phone has not synced its list yet this launch: keep ours.
    if let raw = context["contacts"] as? [[String: String]] {
      setContacts(Self.contacts(from: raw))
    }
    Log.info("session from iPhone: \(displayName) (\(contacts.count) contacts)")
    if accountChanged { onAccountChanged?() }
    Task { await refreshFromServer() }
  }

  private static func contacts(from raw: [[String: String]]) -> [Contact] {
    raw.compactMap { c in
      guard let uid = c["uid"], !uid.isEmpty else { return nil }
      return Contact(uid: uid, displayName: c["displayName"] ?? "", phone: c["phone"] ?? "")
    }
  }

  private func setToken(_ value: String) {
    token = value
    Keychain.write(value)
  }

  private func setContacts(_ list: [Contact]) {
    contacts = list.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    if let data = try? JSONEncoder().encode(contacts) {
      defaults.set(data, forKey: "contacts")
    }
  }

  /// The roster relation is admin-managed and always complete; the phone's list
  /// also has people found through its address book. Union by uid, phone wins.
  private func mergeContacts(_ roster: [Contact]) {
    var byId = Dictionary(uniqueKeysWithValues: roster.map { ($0.uid, $0) })
    for c in contacts { byId[c.uid] = c }
    setContacts(Array(byId.values))
  }

  private func signOut() {
    let wasSignedIn = isSignedIn
    if wasSignedIn, let token { onWillSignOut?(userId, token, deviceId) }
    token = nil
    userId = ""
    displayName = ""
    contacts = []
    Keychain.delete()
    for key in ["userId", "displayName", "contacts"] { defaults.removeObject(forKey: key) }
    if wasSignedIn { onAccountChanged?() }
  }
}

extension AppSession: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    let context = session.receivedApplicationContext
    guard !context.isEmpty else { return }
    Task { @MainActor in self.apply(context: context) }
  }

  nonisolated func session(
    _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    Task { @MainActor in self.apply(context: applicationContext) }
  }
}

/// The auth token, in the Keychain rather than UserDefaults: it is a three-year
/// credential for the account.
enum Keychain {
  private static let service = "com.unnanego.freecaller.watch.pb"
  private static let account = "token"

  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  static func read() -> String? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
      let data = out as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func write(_ value: String) {
    let data = Data(value.utf8)
    let update: [String: Any] = [kSecValueData as String: data]
    if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      // Readable while the watch is locked on the wrist: an incoming call
      // arrives exactly then.
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      SecItemAdd(add as CFDictionary, nil)
    }
  }

  static func delete() {
    SecItemDelete(query as CFDictionary)
  }
}
