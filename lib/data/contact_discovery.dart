import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../core/log.dart';
import 'models.dart';

/// That phone number or email address is already on the roster.
class InviteExistsException implements Exception {
  const InviteExistsException();
}

/// The backend could not be asked which numbers are registered.
///
/// Distinct from "nobody matched", and the distinction matters: this used to be
/// swallowed into an empty match map, which is indistinguishable from a roster
/// where none of your contacts use the app. Since discovery now re-runs on every
/// resume, one dropped request was enough to blank the Contacts list, the
/// device-name map and the Siri vocabulary — so callers must be able to tell
/// "found nothing" from "could not look".
class ContactMatchException implements Exception {
  const ContactMatchException(this.cause);

  final Object cause;

  @override
  String toString() => 'ContactMatchException: $cause';
}

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

/// Maps a registered user's uid to the name the current user has them saved
/// under in their device address book, so device names win over the
/// server-provisioned display name everywhere the person appears.
class ContactNames {
  const ContactNames(this._byUid);

  final Map<String, String> _byUid;

  static const empty = ContactNames({});

  /// The device-book name for [uid] if we have one, else [fallback].
  String resolve(String uid, String fallback) {
    final name = _byUid[uid];
    return (name != null && name.isNotEmpty) ? name : fallback;
  }
}

/// WhatsApp/Telegram-style discovery: reads the device address book and asks
/// the backend which of those numbers belong to registered users. A local
/// allow-list (the in-app "contact access" sheet) further narrows which of
/// them surface — mirroring the design's granular permission model.
///
/// This is a sighted-family convenience — the blind primary user only answers
/// calls and uses Siri, so it never drives their call flow.
class ContactDiscoveryRepo {
  ContactDiscoveryRepo(this._pb);

  final PocketBase _pb;

  // Persist the set of BLOCKED device ids, so a brand-new contact defaults to
  // allowed (like WhatsApp) without us having to enumerate everyone up front.
  static const _blockedKey = 'contactAccessBlocked';

  /// Bumped whenever the allow-list changes. The access sheet and the Contacts
  /// screen are siblings in an [IndexedStack], so the screen is never rebuilt
  /// (let alone re-run initState) when the sheet closes — without this, a
  /// contact switched off in the sheet stayed on the Contacts list until the
  /// app was restarted, which read as "removing access does nothing".
  final revision = ValueNotifier<int>(0);

  // Whether the user has explicitly agreed to send their address-book numbers
  // to our server for matching. Discovery uploads NOTHING until this is set —
  // required by App Store Guideline 5.1.2 (inform + consent before uploading
  // Contacts). The OS contacts permission alone is not this consent.
  static const _uploadConsentKey = 'contactUploadConsent';

  /// Has the user agreed to upload their contacts' numbers for matching?
  Future<bool> hasUploadConsent() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_uploadConsentKey) ?? false;
  }

  /// Record the user's explicit agreement to upload numbers for matching.
  Future<void> grantUploadConsent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_uploadConsentKey, true);
  }

  /// Current access, without prompting. iOS "limited" access (partial contact
  /// selection) counts as granted. Uses flutter_contacts' own permission API
  /// (drives CNContactStore directly) rather than permission_handler, whose
  /// request path fails silently on iOS 26 here.
  Future<bool> hasPermission() =>
      fc.FlutterContacts.permissions.has(fc.PermissionType.read);

  /// Invites someone by name, phone and email: provisions their account (or
  /// reuses one that already exists), links the two of you as mutual contacts,
  /// and emails them which address to sign in with.
  ///
  /// Throws [InviteExistsException] when that number or address already
  /// belongs to someone. A person is one account, and quietly linking to the
  /// existing one would mean mailing the invitation to an address the inviter
  /// never typed — which cannot be explained without disclosing it.
  ///
  /// Returns whether the invitation email went out. By then the invite has
  /// already succeeded, so a send failure is reported rather than thrown: the
  /// inviter can pass the address along themselves.
  Future<bool> invite(String name, String phone, String email) async {
    try {
      final result = await _pb.send<Map<String, dynamic>>(
        Config.pbInvitePath,
        method: 'POST',
        body: {'name': name, 'phone': phone, 'email': email},
      );
      return result['emailed'] == true;
    } on ClientException catch (e) {
      if (e.statusCode == 409) throw const InviteExistsException();
      rethrow;
    }
  }

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
  /// status. Returns null if the user hasn't consented to uploading numbers or
  /// contacts permission isn't granted — in either case nothing is read or
  /// sent to the server (Guideline 5.1.2: no upload before consent).
  Future<List<DiscoveredContact>?> loadDeviceContacts() async {
    if (!await hasUploadConsent()) return null;
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

  /// uid -> device address-book name, for every matched contact (ignores the
  /// allow-list: even a hidden contact should show their saved name if they
  /// call). Empty if permission isn't granted.
  Future<Map<String, String>> deviceNamesByUid() async {
    final all = await loadDeviceContacts();
    if (all == null) return const {};
    return {
      for (final c in all)
        if (c.onApp) c.uid!: c.name,
    };
  }

  Future<Set<String>> blockedIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_blockedKey) ?? const []).toSet();
  }

  /// Serialises the read-modify-write below. Toggling is a tap, and the sheet
  /// does not await it: two quick taps would otherwise both read the old list
  /// and the second write would lose the first one's change.
  Future<void> _writes = Future.value();

  Future<void> setAllowed(String deviceId, bool allowed) {
    _writes = _writes.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final blocked = (prefs.getStringList(_blockedKey) ?? const []).toSet();
      if (allowed) {
        blocked.remove(deviceId);
      } else {
        blocked.add(deviceId);
      }
      await prefs.setStringList(_blockedKey, blocked.toList());
      revision.value++;
    });
    return _writes;
  }

  /// Ask the backend which numbers belong to registered users → {e164: uid}.
  ///
  /// Throws [ContactMatchException] if the request failed, rather than reporting
  /// an empty roster — see that class for why.
  Future<Map<String, String>> _matchRegistered(List<String> phones) async {
    try {
      final result = await _pb.send<Map<String, dynamic>>(
        Config.pbMatchContactsPath,
        method: 'POST',
        body: {'phones': phones},
      );
      final matches = (result['matches'] as List)
          .map((m) => Map<String, dynamic>.from(m as Map));
      return {
        for (final m in matches)
          if (m['phone'] is String) m['phone'] as String: m['uid'] as String,
      };
    } catch (e) {
      log('matchContacts failed', error: e);
      throw ContactMatchException(e);
    }
  }

  /// Parse to E.164. A leading "+" carries its own country code, so parse it
  /// as-is; only bare national numbers (no "+") default to RU. Passing
  /// destinationCountry with a "+" number makes phone_numbers_parser IGNORE the
  /// "+" and force RU — mangling e.g. +972… into +772… — which silently dropped
  /// every non-Russian contact.
  String? _toE164(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final parsed = trimmed.startsWith('+')
          ? PhoneNumber.parse(trimmed)
          : PhoneNumber.parse(trimmed, destinationCountry: IsoCode.RU);
      return parsed.isValid() ? parsed.international : null;
    } catch (_) {
      return null;
    }
  }
}
