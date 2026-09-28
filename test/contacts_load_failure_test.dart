import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freecaller/data/contact_discovery.dart';
import 'package:freecaller/l10n/app_localizations.dart';
import 'package:freecaller/ui/contacts_screen.dart';
import 'package:pocketbase/pocketbase.dart';

/// Fails the load with whatever it is handed, until told to stop.
class _FlakyDiscovery extends ContactDiscoveryRepo {
  _FlakyDiscovery(this.error) : super(PocketBase('http://localhost'));

  Object? error;

  @override
  Future<bool> hasUploadConsent() async => true;

  @override
  Future<List<DiscoveredContact>?> loadAllowedOnApp() async {
    if (error != null) throw error!;
    return const [
      DiscoveredContact(deviceId: '1', name: 'Аида', uid: 'u1', phone: '+79150000001'),
    ];
  }
}

Widget host(Widget child) => MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

const _empty = 'Пока никого из ваших контактов нет в Звонилке.';

void main() {
  for (final error in <Object>[
    const ContactMatchException('offline'),
    // Not only the exception the repo documents: the contacts plugin throws its
    // own, and that one used to leave the spinner up for good.
    PlatformException(code: 'boom'),
  ]) {
    testWidgets('a failed first load says so and can be retried ($error)',
        (tester) async {
      final discovery = _FlakyDiscovery(error);
      await tester.pumpWidget(host(ContactsScreen(
        discovery: discovery,
        onCall: (_, {required video}) {},
      )));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(_empty), findsNothing);
      expect(find.bySemanticsLabel('Повторить'), findsOneWidget);

      discovery.error = null;
      await tester.tap(find.bySemanticsLabel('Повторить'));
      await tester.pumpAndSettle();

      expect(find.text('Аида'), findsOneWidget);
      expect(find.bySemanticsLabel('Повторить'), findsNothing);
    });
  }

  testWidgets('the invite fields are named for a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(ContactsScreen(
      discovery: _FlakyDiscovery(null),
      onCall: (_, {required video}) {},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Пригласить'));
    await tester.pumpAndSettle();

    for (final label in ['Имя', 'Телефон', 'Почта']) {
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        matchesSemantics(
          label: label,
          isTextField: true,
          hasTapAction: true,
          hasFocusAction: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
        reason: label,
      );
    }
    handle.dispose();
  });
}
