import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_messenger/features/settings/privacy_copy.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';

void main() {
  testWidgets('privacy copy states live end-to-end encryption', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SettingsScreen()),
    );

    expect(find.text(PrivacyCopy.title), findsOneWidget);
    expect(find.text(PrivacyCopy.subtitle), findsOneWidget);
    expect(find.textContaining('planned'), findsNothing);
    expect(find.textContaining('end-to-end encrypted'), findsOneWidget);
  });

  testWidgets('logout cancel does not invoke handler', (tester) async {
    var calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          onLogout: () async {
            calls++;
          },
        ),
      ),
    );

    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    expect(find.text('Log out?'), findsOneWidget);
    await tester.tap(find.text('Stay signed in'));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.text('Log out'), findsOneWidget);
  });

  testWidgets('logout confirmation invokes handler once', (tester) async {
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
    await tester.pumpAndSettle();

    expect(find.text('Log out?'), findsOneWidget);
    // Confirm button is the dialog action labeled "Log out".
    await tester.tap(find.widgetWithText(TextButton, 'Log out'));
    await tester.pump();

    expect(find.text('Logging out...'), findsOneWidget);

    await tester.tap(find.text('Logging out...'));
    await tester.pump();

    allowLogout.complete();
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('Log out'), findsWidgets);
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
    await tester.tap(find.widgetWithText(TextButton, 'Log out'));
    await tester.pumpAndSettle();

    expect(
      find.text('Unable to log out. Check your connection and retry.'),
      findsOneWidget,
    );
    expect(find.text('Log out'), findsOneWidget);
  });
}
