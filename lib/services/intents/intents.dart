import '../../data/models.dart';

class OutgoingCallRequest {
  const OutgoingCallRequest({required this.contactUid, required this.video});

  final String contactUid;
  final bool video;
}

/// Platform seam for OS voice assistants. On iOS this bridges the SiriKit
/// Intents extension (INStartCallIntent): outgoing-call requests arrive
/// from AppDelegate over a MethodChannel, and the roster is pushed the
/// other way (App Group snapshot + INVocabulary) so Siri can resolve and
/// recognize contact names.
abstract class IntentsBridge {
  /// Call requests from the OS (e.g. «Позвони Аиде через Звонилку»; Siri's
  /// video-call phrasing sets [OutgoingCallRequest.video]).
  Stream<OutgoingCallRequest> get startCallRequests;

  /// Publishes the roster to the OS layer whenever it changes.
  Future<void> syncContacts(List<Contact> contacts);

  /// Call once a listener is attached: tells the native side Dart is live
  /// and flushes any call request buffered during a Siri cold launch.
  Future<void> ready();
}

class NoopIntentsBridge implements IntentsBridge {
  @override
  Stream<OutgoingCallRequest> get startCallRequests => const Stream.empty();

  @override
  Future<void> syncContacts(List<Contact> contacts) async {}

  @override
  Future<void> ready() async {}
}
