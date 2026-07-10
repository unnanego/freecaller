import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freecaller/data/models.dart';
import 'package:freecaller/l10n/app_localizations.dart';
import 'package:freecaller/ui/call_type_screen.dart';

const aida = Contact(uid: 'u1', displayName: 'Аида', phone: '+79150000001');

Widget host(Widget child) => MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    );

void main() {
  testWidgets('offers voice, video and cancel with proper semantics',
      (tester) async {
    Contact? started;
    bool? startedVideo;
    var cancelled = false;

    await tester.pumpWidget(host(CallTypeScreen(
      contact: aida,
      onStart: (c, {required video}) {
        started = c;
        startedVideo = video;
      },
      onCancel: () => cancelled = true,
    )));

    expect(find.textContaining('Аида'), findsOneWidget);
    expect(find.bySemanticsLabel('Обычный звонок'), findsOneWidget);
    expect(find.bySemanticsLabel('Видеозвонок'), findsOneWidget);

    await tester.tap(find.text('Видеозвонок'));
    expect(started?.uid, 'u1');
    expect(startedVideo, isTrue);

    await tester.tap(find.text('Обычный звонок'));
    expect(startedVideo, isFalse);

    await tester.tap(find.text('Назад'));
    expect(cancelled, isTrue);
  });
}
