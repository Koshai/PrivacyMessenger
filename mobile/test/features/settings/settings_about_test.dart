import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/settings/about_copy.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';

void main() {
  testWidgets('About and licenses are reachable from Settings', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));

    expect(find.text('About'), findsOneWidget);
    expect(find.text('Open-source licenses'), findsOneWidget);

    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.text(AboutCopy.appName), findsWidgets);
    expect(find.textContaining(AboutCopy.summary.split('.').first), findsOneWidget);
    expect(find.textContaining('@'), findsNothing);
    expect(find.textContaining('http'), findsNothing);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open-source licenses'));
    await tester.pumpAndSettle();
    expect(find.text('Licenses'), findsOneWidget);
  });
}
