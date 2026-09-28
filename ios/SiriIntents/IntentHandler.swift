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
    let roster = ContactsStore.load()

    // A person WE already resolved comes back carrying the uid we put in
    // customIdentifier — after a disambiguation pick, and again on Siri's
    // later resolve passes. Accept it as final. Matching by name a second time
    // cannot tell two contacts with the same display name apart: it found both
    // again, answered .disambiguation again, and Siri read the same list out
    // forever — to someone who cannot see the screen to tap their way out.
    // Checked against the roster so a uid from a previous sign-in resolves
    // nobody rather than dialling a stranger.
    if let uid = person.customIdentifier, !uid.isEmpty,
      let known = roster.first(where: { $0.uid == uid })
    {
      completion([.success(with: inPerson(known))])
      return
    }

    let spoken = person.spokenPhrase ?? person.displayName
    let matches = ContactsStore.matches(spoken, in: roster)

    switch matches.count {
    case 0:
      completion([.unsupported()])
    case 1:
      completion([.success(with: inPerson(matches[0]))])
    default:
      // Siri reads the options aloud — ideal for a blind user.
      // Every option carries its uid in customIdentifier (see inPerson), which
      // is what the early return above recognises once one has been picked.
      completion([.disambiguation(with: matches.map { inPerson($0, among: matches) })])
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

  /// `among`: the options this person is being read out alongside. Two that
  /// share a display name would be read as «Аида» and «Аида» — no choice at
  /// all by ear — so those get the last digits of their number appended.
  private func inPerson(_ contact: RosterContact, among options: [RosterContact] = []) -> INPerson {
    var name = contact.displayName
    let twins = options.filter {
      $0.displayName.lowercased() == contact.displayName.lowercased()
    }
    if twins.count > 1 {
      let digits = contact.phone.filter { $0.isNumber }
      if digits.count >= 4 { name += ", номер на \(digits.suffix(4))" }
    }
    return INPerson(
      personHandle: INPersonHandle(value: contact.phone, type: .phoneNumber),
      nameComponents: nil,
      displayName: name,
      image: nil,
      contactIdentifier: nil,
      customIdentifier: contact.uid)
  }
}
