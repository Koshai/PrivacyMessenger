import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/main.dart';

void main() {
  group('Private Messenger Navigation', () {
    testWidgets('Displays all three navigation tabs', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MainNavigation()));

      expect(find.text('Chats'), findsWidgets);
      expect(find.text('Friends'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('Opens Friends screen', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MainNavigation()));

      await tester.tap(find.byIcon(Icons.people_outline));
      await tester.pumpAndSettle();

      expect(find.text('Your friends are private'), findsOneWidget);
    });

    testWidgets('Opens Settings screen', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MainNavigation()));

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Easy Mode'), findsOneWidget);
    });

    testWidgets('Displays empty chat state', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MainNavigation()));

      expect(find.text('No conversations yet'), findsOneWidget);
      expect(find.text('Add friends'), findsOneWidget);
    });

    testWidgets('Empty chats Add friends opens Friends tab', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MainNavigation()));

      await tester.tap(find.text('Add friends'));
      await tester.pumpAndSettle();

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 1);
      expect(find.text('Your friends are private'), findsWidgets);
    });
  });
}
