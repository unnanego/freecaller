import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freecaller/data/contact_discovery.dart';
import 'package:freecaller/data/models.dart';
import 'package:freecaller/data/user_repo.dart';
import 'package:freecaller/l10n/app_localizations.dart';
import 'package:freecaller/ui/settings_screen.dart';
import 'package:freecaller/ui/theme/modernist.dart';
import 'package:pocketbase/pocketbase.dart';

const aida = UserProfile(
  uid: 'u1',
  phone: '+79150000001',
  displayName: 'Аида',
  contactUids: [],
);

Widget host(Widget child) => MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // The real screen lives inside MainShell's Scaffold; InkWell needs it.
      home: Scaffold(body: child),
    );

/// The screen with every callback stubbed; pass only the ones a test cares
/// about. The discovery repo is only reached through the contact-access row,
/// which no test here opens.
Future<void> pumpSettings(
  WidgetTester tester, {
  UserProfile profile = aida,
  Future<void> Function(String phone)? onSavePhone,
  Future<void> Function(String email)? onRequestEmailChange,
  Future<void> Function(String code)? onConfirmEmailChange,
}) async {
  await tester.pumpWidget(host(SettingsScreen(
    profile: profile,
    signInEmail: 'aida@mail.ru',
    discovery: ContactDiscoveryRepo(PocketBase('http://localhost')),
    onSignOut: () async {},
    onSaveName: (_) async {},
    onSavePhone: onSavePhone ?? (_) async {},
    onSaveAvatar: (Uint8List _, String _) async {},
    onRemoveAvatar: () async {},
    onRequestEmailChange: onRequestEmailChange ?? (_) async {},
    onConfirmEmailChange: onConfirmEmailChange ?? (_) async {},
    onReport: (_) async {},
    onDeleteAccount: () async {},
  )));
  await tester.pumpAndSettle();
}

/// The email-change button sits below the fold on a test-sized screen.
Future<void> openEmailSheet(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, -400));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Изменить почту'));
  await tester.pumpAndSettle();
}

/// The phone field is the second editable one (name, then phone).
Finder phoneField() => find.byType(TextField).at(1);

void main() {
  testWidgets('saving a new number sends it to the server', (tester) async {
    String? saved;
    await pumpSettings(tester, onSavePhone: (phone) async => saved = phone);

    await tester.enterText(phoneField(), '+79150000002');
    await tester.tap(find.text('Сохранить').last);
    await tester.pumpAndSettle();

    expect(saved, '+79150000002');
    expect(find.text('Сохранено'), findsOneWidget);
  });

  testWidgets('a number another account holds shows the server\'s reason',
      (tester) async {
    await pumpSettings(
      tester,
      onSavePhone: (_) async =>
          throw const ProfileConflictException('Этот номер уже занят'),
    );

    await tester.enterText(phoneField(), '+79150000003');
    await tester.tap(find.text('Сохранить').last);
    await tester.pumpAndSettle();

    expect(find.text('Этот номер уже занят'), findsOneWidget);
  });

  testWidgets('changing the email asks for a code before it applies',
      (tester) async {
    String? requested;
    String? confirmed;
    await pumpSettings(
      tester,
      onRequestEmailChange: (email) async => requested = email,
      onConfirmEmailChange: (code) async => confirmed = code,
    );

    await openEmailSheet(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'new@mail.ru');
    await tester.tap(find.text('Прислать код'));
    await tester.pumpAndSettle();

    // Nothing has changed yet — the second step is the whole point.
    expect(requested, 'new@mail.ru');
    expect(confirmed, isNull);
    expect(find.text('Код из письма'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, '12345678');
    await tester.tap(find.text('Подтвердить'));
    await tester.pumpAndSettle();

    expect(confirmed, '12345678');
    expect(find.textContaining('Почта изменена'), findsOneWidget);
  });

  testWidgets('a rejected address keeps the sheet on the first step',
      (tester) async {
    await pumpSettings(
      tester,
      onRequestEmailChange: (_) async =>
          throw const ProfileConflictException('Этот адрес уже занят'),
    );

    await openEmailSheet(tester);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'taken@mail.ru');
    await tester.tap(find.text('Прислать код'));
    await tester.pumpAndSettle();

    expect(find.text('Этот адрес уже занят'), findsOneWidget);
    expect(find.text('Код из письма'), findsNothing);
  });

  testWidgets('the picture offers camera and library, and nothing to remove '
      'when there is no picture', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.byType(InitialsTile).first);
    await tester.pumpAndSettle();

    expect(find.text('Сделать снимок'), findsOneWidget);
    expect(find.text('Выбрать из галереи'), findsOneWidget);
    expect(find.text('Удалить фото'), findsNothing);
  });

  testWidgets('an existing picture can be removed', (tester) async {
    await pumpSettings(
      tester,
      profile: const UserProfile(
        uid: 'u1',
        phone: '+79150000001',
        displayName: 'Аида',
        contactUids: [],
        avatarUrl: 'http://localhost/api/files/users/u1/photo.jpg',
      ),
    );

    await tester.tap(find.byType(InitialsTile).first);
    await tester.pumpAndSettle();

    expect(find.text('Удалить фото'), findsOneWidget);
  });
}
