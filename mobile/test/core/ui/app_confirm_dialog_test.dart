import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_messenger/core/ui/app_confirm_dialog.dart';
import 'package:private_messenger/core/ui/app_error_panel.dart';

void main() {
  testWidgets('confirm dialog cancel returns false', (tester) async {
    var confirmed = true;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  confirmed = await showAppConfirmDialog(
                    context: context,
                    title: 'Delete?',
                    message: 'Are you sure?',
                    confirmLabel: 'Delete',
                    isDestructive: true,
                  );
                },
                child: const Text('Open'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(confirmed, isFalse);
  });

  testWidgets('error panel exposes primary and secondary actions', (
    tester,
  ) async {
    var primary = 0;
    var secondary = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppErrorPanel(
            title: 'Unavailable',
            message: 'Check your connection.',
            primaryLabel: 'Try again',
            onPrimary: () => primary++,
            secondaryLabel: 'Clear saved sign-in',
            onSecondary: () => secondary++,
          ),
        ),
      ),
    );

    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.tap(find.text('Clear saved sign-in'));
    expect(primary, 1);
    expect(secondary, 1);
  });
}
