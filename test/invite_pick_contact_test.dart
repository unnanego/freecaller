import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freecaller/data/contact_discovery.dart';
import 'package:freecaller/l10n/app_localizations.dart';
import 'package:freecaller/ui/contacts_screen.dart';
import 'package:pocketbase/pocketbase.dart';

/// Stands in for the real repo: everything the Contacts screen loads is stubbed
/// out, so the test only exercises the invite sheet's picker path.
class _FakeDiscovery extends ContactDiscoveryRepo {
  _FakeDiscovery({this.picked, this.error}) : super(PocketBase('http://localhost'));

  final PickedContact? picked;
  final Object? error;

  @override
  Future<bool> hasUploadConsent() async => true;

  @override
  Future<List<DiscoveredContact>?> loadAllowedOnApp() async => const [];

  @override
  Future<PickedContact?> pickContact() async {
    if (error != null) throw error!;
    return picked;
  }
}

Widget host(Widget child) => MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

/// The invite sheet's three fields, in order: name, phone, email.
String _fieldText(WidgetTester tester, int index) =>
    tester.widgetList<TextField>(find.byType(TextField)).elementAt(index).controller!.text;

Future<void> openInviteSheet(WidgetTester tester, ContactDiscoveryRepo discovery) async {
  await tester.pumpWidget(host(ContactsScreen(
    discovery: discovery,
    onCall: (_, {required video}) {},
  )));
  await tester.pumpAndSettle();
  await tester.tap(find.bySemanticsLabel('Пригласить'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a picked contact fills name, number and email', (tester) async {
    await openInviteSheet(
      tester,
      _FakeDiscovery(
        picked: const PickedContact(
          name: 'Аида',
          phones: ['+79150000001'],
          email: 'aida@mail.ru',
        ),
      ),
    );

    await tester.tap(find.text('Выбрать из контактов'));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, 0), 'Аида');
    expect(_fieldText(tester, 1), '+79150000001');
    expect(_fieldText(tester, 2), 'aida@mail.ru');
  });

  testWidgets('a contact with several numbers asks which one', (tester) async {
    await openInviteSheet(
      tester,
      _FakeDiscovery(
        picked: const PickedContact(
          name: 'Аида',
          phones: ['+79150000001', '+79150000002'],
        ),
      ),
    );

    await tester.tap(find.text('Выбрать из контактов'));
    await tester.pumpAndSettle();
    expect(find.text('Какой номер'), findsOneWidget);

    await tester.tap(find.text('+79150000002'));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, 1), '+79150000002');
  });

  testWidgets('a contact without a number says so instead of filling the form',
      (tester) async {
    await openInviteSheet(
      tester,
      _FakeDiscovery(
        picked: const PickedContact(name: 'Аида', phones: []),
      ),
    );

    await tester.tap(find.text('Выбрать из контактов'));
    await tester.pumpAndSettle();

    expect(find.textContaining('нет номера телефона'), findsOneWidget);
    expect(_fieldText(tester, 1), '+'); // untouched
  });

  testWidgets('refused contacts access explains itself', (tester) async {
    await openInviteSheet(
      tester,
      _FakeDiscovery(error: const ContactPickDeniedException()),
    );

    await tester.tap(find.text('Выбрать из контактов'));
    await tester.pumpAndSettle();

    expect(find.textContaining('разрешите приложению доступ к контактам'),
        findsOneWidget);
  });
}
