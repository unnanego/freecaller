import 'package:cloud_firestore/cloud_firestore.dart';

import 'models.dart';

class UserRepo {
  UserRepo(this._db);

  final FirebaseFirestore _db;

  /// The owner may edit their own display name (rules restrict to this field).
  Future<void> updateDisplayName(String uid, String name) =>
      _db.collection('users').doc(uid).update({'displayName': name});

  /// The user's permanent login code (owner-only private doc) — shown in
  /// Settings so they can sign back in on another device.
  Stream<String?> watchLoginCode(String uid) => _db
      .doc('users/$uid/private/creds')
      .snapshots()
      .map((doc) => doc.data()?['loginCode'] as String?);

  Stream<UserProfile?> watchProfile(String uid) => _db
      .collection('users')
      .doc(uid)
      .snapshots()
      .map((doc) => doc.exists ? UserProfile.fromDoc(doc) : null);

  /// Resolves the profile's contact uids into an ordered contact list.
  /// Rosters are tiny (1–15 people), so per-doc reads are fine.
  Stream<List<Contact>> watchContacts(String uid) =>
      watchProfile(uid).asyncMap((profile) async {
        if (profile == null || profile.contactUids.isEmpty) return const <Contact>[];
        final docs = await Future.wait(
          profile.contactUids.map((c) => _db.collection('users').doc(c).get()),
        );
        return [
          for (final doc in docs)
            if (doc.exists)
              Contact(
                uid: doc.id,
                displayName: doc.data()!['displayName'] as String? ?? '',
                phone: doc.data()!['phone'] as String? ?? '',
              ),
        ];
      });
}
