import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';

/// Builds the app's single PocketBase client, with its session persisted.
///
/// The default [AuthStore] lives in memory only, which would sign every device
/// out on relaunch — the one failure this app cannot have (the primary user is
/// blind and recovering means someone reading an emailed code aloud). So the
/// token is written to shared_preferences through [AsyncAuthStore] and reloaded
/// synchronously at construction, which is what lets `authState` know who is
/// signed in before the first frame.
Future<PocketBase> createPocketBase() async {
  const key = 'pbAuth';
  final prefs = await SharedPreferences.getInstance();

  final store = AsyncAuthStore(
    save: (data) async => prefs.setString(key, data),
    initial: prefs.getString(key),
    clear: () async => prefs.remove(key),
  );

  return PocketBase(Config.pbUrl, authStore: store);
}
