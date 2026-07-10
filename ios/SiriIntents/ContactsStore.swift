import Foundation

struct RosterContact: Codable {
  let uid: String
  let displayName: String
  let phone: String
}

/// Reads the roster snapshot the main app writes into the App Group
/// container (AppDelegate.syncContacts). The extension has no network and
/// no Flutter — this file is its whole world.
enum ContactsStore {
  static let appGroupId = "group.com.unnanego.freecaller"
  static let contactsFile = "contacts.json"

  static func load() -> [RosterContact] {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupId),
      let data = try? Data(contentsOf: container.appendingPathComponent(contactsFile)),
      let contacts = try? JSONDecoder().decode([RosterContact].self, from: data)
    else { return [] }
    return contacts
  }

  /// Case-insensitive prefix match with ё→е folding — tolerant of how Siri
  /// transcribes Russian names («Аида», «аиде» after declension, etc.).
  static func matches(_ spoken: String, in contacts: [RosterContact]) -> [RosterContact] {
    let needle = normalize(spoken)
    guard !needle.isEmpty else { return [] }
    let exact = contacts.filter { normalize($0.displayName) == needle }
    if !exact.isEmpty { return exact }
    return contacts.filter { contact in
      let name = normalize(contact.displayName)
      return name.hasPrefix(needle) || needle.hasPrefix(name)
    }
  }

  private static func normalize(_ value: String) -> String {
    value.lowercased()
      .replacingOccurrences(of: "ё", with: "е")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
