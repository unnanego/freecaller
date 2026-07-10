import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freecaller/data/models.dart';
import 'package:freecaller/l10n/app_localizations.dart';
import 'package:freecaller/ui/home_screen.dart';

Widget host(Widget child) => MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    );

const aida = Contact(uid: 'u1', displayName: 'Аида', phone: '+79150000001');
const pavel = Contact(uid: 'u2', displayName: 'Павел', phone: '+79150000002');

void main() {
  testWidgets('renders one giant button per contact with call semantics',
      (tester) async {
    Contact? called;
    await tester.pumpWidget(host(HomeScreen(
      contacts: const [aida, pavel],
      missedFrom: null,
      onCall: (c) => called = c,
    )));

    expect(find.text('Аида'), findsOneWidget);
    expect(find.text('Павел'), findsOneWidget);
    // VoiceOver reads the action, not just the name.
    expect(find.bySemanticsLabel('Позвонить Аида'), findsOneWidget);

    await tester.tap(find.text('Аида'));
    expect(called?.uid, 'u1');
  });

  testWidgets('missed-call banner calls back on tap', (tester) async {
    Contact? called;
    await tester.pumpWidget(host(HomeScreen(
      contacts: const [aida],
      missedFrom: pavel,
      onCall: (c) => called = c,
    )));

    expect(find.text('Пропущенный звонок: Павел'), findsOneWidget);
    await tester.tap(find.text('Пропущенный звонок: Павел'));
    expect(called?.uid, 'u2');
  });

  testWidgets('empty roster shows guidance instead of blank screen',
      (tester) async {
    await tester.pumpWidget(host(HomeScreen(
      contacts: const [],
      missedFrom: null,
      onCall: (_) {},
    )));
    expect(find.textContaining('Нет контактов'), findsOneWidget);
  });
}
