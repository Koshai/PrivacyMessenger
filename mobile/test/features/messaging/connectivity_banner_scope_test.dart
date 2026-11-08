import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/ui/connectivity_banner.dart';
import 'package:private_messenger/main.dart';

void main() {
  testWidgets('main tabs do not mount a global ConnectivityBanner', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MainNavigation()));
    await tester.pumpAndSettle();

    expect(find.byType(ConnectivityBanner), findsNothing);
  });

  testWidgets('single ConnectivityBanner renders one strip', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ConnectivityBanner(state: ConnectivityBannerState.unreachable),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(ConnectivityBanner), findsOneWidget);
    expect(find.textContaining('Can’t reach Private Messenger'), findsOneWidget);
  });
}
