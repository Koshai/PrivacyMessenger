import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/settings/privacy_copy.dart';
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

    testWidgets('Opens Settings without inert Easy Mode control', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MainNavigation()));

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Easy Mode'), findsNothing);
      expect(find.text(PrivacyCopy.title), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
      expect(find.text('Open-source licenses'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
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

    testWidgets('large text still shows hang-up-adjacent nav destinations', (
      tester,
    ) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: const MaterialApp(home: MainNavigation()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Chats'), findsWidgets);
      expect(find.text('Friends'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Add friends'), findsOneWidget);
    });
  });
}
