import Intents

/// SiriKit calling-domain handler: «Позвони Аиде через Звонилку». Siri's
/// Russian calling grammar is built in; we only resolve the spoken name
/// against the family roster and hand off to the app (.continueInApp),
/// which starts the CallKit call.
class IntentHandler: INExtension, INStartCallIntentHandling {

  override func handler(for intent: INIntent) -> Any {
    return self
  }

  func resolveContacts(
    for intent: INStartCallIntent,
    with completion: @escaping ([INStartCallContactResolutionResult]) -> Void
  ) {
    guard let person = intent.contacts?.first else {
      completion([.needsValue()])
      return
    }
    let spoken = person.spokenPhrase ?? person.displayName
    let roster = ContactsStore.load()
    let matches = ContactsStore.matches(spoken, in: roster)

    switch matches.count {
    case 0:
      completion([.unsupported()])
    case 1:
      completion([.success(with: inPerson(matches[0]))])
    default:
      // Siri reads the options aloud — ideal for a blind user.
      completion([.disambiguation(with: matches.map(inPerson))])
    }
  }

  func confirm(
    intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void
  ) {
    completion(INStartCallIntentResponse(code: .ready, userActivity: nil))
  }

  func handle(
    intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void
  ) {
    // .continueInApp launches the app with this activity; the SceneDelegate
    // extracts the contact uid and the app fires CXStartCallAction.
    let activity = NSUserActivity(activityType: String(describing: INStartCallIntent.self))
    completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
  }

  private func inPerson(_ contact: RosterContact) -> INPerson {
    INPerson(
      personHandle: INPersonHandle(value: contact.phone, type: .phoneNumber),
      nameComponents: nil,
      displayName: contact.displayName,
      image: nil,
      contactIdentifier: nil,
      customIdentifier: contact.uid)
  }
}
