import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import 'models.dart';

/// One entry from the device address book, annotated with whether the person
/// is a registered Freecaller user.
class DiscoveredContact {
  const DiscoveredContact({
    required this.deviceId,
    required this.name,
    this.uid,
    this.phone,
  });

  final String deviceId;
  final String name;

  /// Registered user id, if this person uses the app; null otherwise.
  final String? uid;

  /// The matched E.164 number (for placing the call), if on the app.
  final String? phone;

  bool get onApp => uid != null;

  /// A callable roster contact (only valid when [onApp]).
  Contact toContact() =>
      Contact(uid: uid!, displayName: name, phone: phone ?? '');
}

/// WhatsApp/Telegram-style discovery: reads the device address book and asks
/// the backend which of those numbers belong to registered users. A local
/// allow-list (the in-app "contact access" sheet) further narrows which of
/// them surface — mirroring the design's granular permission model.
///
/// This is a sighted-family convenience — the blind primary user only answers
/// calls and uses Siri, so it never drives their call flow.
class ContactDiscoveryRepo {
  ContactDiscoveryRepo(this._functions);

  final FirebaseFunctions _functions;

  // Persist the set of BLOCKED device ids, so a brand-new contact defaults to
  // allowed (like WhatsApp) without us having to enumerate everyone up front.
  static const _blockedKey = 'contactAccessBlocked';

  /// Current access, without prompting. iOS "limited" access (partial contact
  /// selection) counts as granted. Uses flutter_contacts' own permission API
  /// (drives CNContactStore directly) rather than permission_handler, whose
  /// request path fails silently on iOS 26 here.
  Future<bool> hasPermission() =>
      fc.FlutterContacts.permissions.has(fc.PermissionType.read);

  /// Requests contacts access. If the OS won't prompt again (already decided),
  /// opens the app's Settings page so the user can flip it on. Returns whether
  /// access is granted now.
  Future<bool> ensureAccess() async {
    final status = await fc.FlutterContacts.permissions.request(fc.PermissionType.read);
    if (status == fc.PermissionStatus.granted ||
        status == fc.PermissionStatus.limited) {
      return true;
    }
    if (status == fc.PermissionStatus.permanentlyDenied ||
        status == fc.PermissionStatus.restricted) {
      await fc.FlutterContacts.permissions.openSettings();
    }
    return false;
  }

  /// Reads the device address book and annotates each contact with on-app
  /// status. Returns null if contacts permission isn't granted.
  Future<List<DiscoveredContact>?> loadDeviceContacts() async {
    if (!await hasPermission()) return null;

    final deviceContacts = await fc.FlutterContacts.getAll(
      properties: {fc.ContactProperty.name, fc.ContactProperty.phone},
    );

    // Flatten to (contact, E.164) and collect every number for one backend call.
    final numbersByContact = <String, List<String>>{};
    final names = <String, String>{};
    final allNumbers = <String>{};
    for (final c in deviceContacts) {
      final id = c.id;
      final name = c.displayName?.trim() ?? '';
      if (id == null || name.isEmpty) continue;
      final nums = <String>[];
      for (final p in c.phones) {
        final e164 = _toE164(p.number);
        if (e164 != null) {
          nums.add(e164);
          allNumbers.add(e164);
        }
      }
      if (nums.isNotEmpty) {
        numbersByContact[id] = nums;
        names[id] = name;
      }
    }
    if (allNumbers.isEmpty) return const [];

    final registered = await _matchRegistered(allNumbers.toList());

    final result = <DiscoveredContact>[
      for (final entry in numbersByContact.entries)
        () {
          final matched = entry.value.firstWhere(
            registered.containsKey,
            orElse: () => '',
          );
          return DiscoveredContact(
            deviceId: entry.key,
            name: names[entry.key]!,
            uid: matched.isEmpty ? null : registered[matched],
            phone: matched.isEmpty ? null : matched,
          );
        }(),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  /// The registered contacts to show on the Contacts screen: on-app and not
  /// blocked in the access sheet. Null if permission was denied.
  Future<List<DiscoveredContact>?> loadAllowedOnApp() async {
    final all = await loadDeviceContacts();
    if (all == null) return null;
    final blocked = await blockedIds();
    return all
        .where((c) => c.onApp && !blocked.contains(c.deviceId))
        .toList();
  }

  Future<Set<String>> blockedIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_blockedKey) ?? const []).toSet();
  }

  Future<void> setAllowed(String deviceId, bool allowed) async {
    final prefs = await SharedPreferences.getInstance();
    final blocked = (prefs.getStringList(_blockedKey) ?? const []).toSet();
    if (allowed) {
      blocked.remove(deviceId);
    } else {
      blocked.add(deviceId);
    }
    await prefs.setStringList(_blockedKey, blocked.toList());
  }

  /// Ask the backend which numbers belong to registered users → {e164: uid}.
  Future<Map<String, String>> _matchRegistered(List<String> phones) async {
    try {
      final result = await _functions
          .httpsCallable('matchContacts')
          .call({'phones': phones});
      final matches = (result.data['matches'] as List)
          .map((m) => Map<String, dynamic>.from(m as Map));
      return {
        for (final m in matches)
          if (m['phone'] is String) m['phone'] as String: m['uid'] as String,
      };
    } catch (e) {
      log('matchContacts failed', error: e);
      return const {};
    }
  }

  /// Parse to E.164 (e.g. "8 916 …" → "+7916…"), defaulting bare locals to RU.
  String? _toE164(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final parsed = PhoneNumber.parse(raw, destinationCountry: IsoCode.RU);
      return parsed.isValid() ? parsed.international : null;
    } catch (_) {
      return null;
    }
  }
}
