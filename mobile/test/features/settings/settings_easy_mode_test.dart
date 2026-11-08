import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/settings/privacy_copy.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';

void main() {
  testWidgets('Easy Mode toggle is removed from Settings', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));

    expect(find.text('Easy Mode'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text(PrivacyCopy.title), findsOneWidget);
  });
}
