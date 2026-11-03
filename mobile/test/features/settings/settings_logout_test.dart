import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_messenger/features/settings/settings_screen.dart';

void main() {
  testWidgets('duplicate logout taps only invoke handler once', (tester) async {
    var calls = 0;
    final allowLogout = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          onLogout: () async {
            calls++;
            await allowLogout.future;
          },
        ),
      ),
    );

    await tester.tap(find.text('Log out'));
    await tester.pump();

    expect(find.text('Logging out...'), findsOneWidget);

    await tester.tap(find.text('Logging out...'));
    await tester.pump();

    allowLogout.complete();
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('Log out'), findsOneWidget);
  });

  testWidgets('logout network failure shows retry message', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          onLogout: () async {
            throw Exception('network');
          },
        ),
      ),
    );

    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    expect(
      find.text('Unable to log out. Check your connection and retry.'),
      findsOneWidget,
    );
    expect(find.text('Log out'), findsOneWidget);
  });
}
