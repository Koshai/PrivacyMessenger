import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/messaging/safety_number_copy.dart';
import 'package:private_messenger/features/messaging/safety_number_screen.dart';

void main() {
  test('formatSafetyFingerprintHex groups without changing digits', () {
    const raw = 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
    final formatted = formatSafetyFingerprintHex(raw);
    expect(formatted.replaceAll(' ', '').toLowerCase(), raw);
    expect(formatted, contains('AABB'));
    expect(formatted.split(' ').every((g) => g.length <= 4), isTrue);
  });

  test('trust labels never claim automatic verification', () {
    expect(safetyTrustLabel(SafetyTrustState.unverified), 'Not verified');
    expect(safetyTrustLabel(SafetyTrustState.verified), 'Verified by you');
    expect(
      safetyTrustLabel(SafetyTrustState.changed),
      'Safety number changed',
    );
    expect(safetyTrustLabel(SafetyTrustState.verified), isNot(contains('automatic')));
  });

  testWidgets('shows key-change warning and human trust labels', (tester) async {
    SafetyTrustState? latest;
    const peerHex = 'aabbccddeeff00112233445566778899';
    await tester.pumpWidget(
      MaterialApp(
        home: SafetyNumberScreen(
          peerEmail: 'bob@example.test',
          peerFingerprintHex: peerHex,
          localFingerprintHex: '00112233445566778899aabbccddeeff',
          initialTrust: SafetyTrustState.changed,
          onTrustChanged: (s) => latest = s,
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text(SafetyNumberCopy.changedWarning), findsOneWidget);
    expect(find.textContaining('Trust state:'), findsNothing);
    expect(find.byKey(const Key('safety-trust-status')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('safety-trust-status'))).data,
      'Status: ${safetyTrustLabel(SafetyTrustState.changed)}',
    );
    expect(find.text(SafetyNumberCopy.encryptionVsVerification), findsOneWidget);

    await tester.ensureVisible(find.text('Mark as verified'));
    await tester.tap(find.text('Mark as verified'));
    await tester.pumpAndSettle();
    expect(latest, SafetyTrustState.verified);
    expect(
      tester.widget<Text>(find.byKey(const Key('safety-trust-status'))).data,
      'Status: ${safetyTrustLabel(SafetyTrustState.verified)}',
    );
    expect(
      find.textContaining('never marks a contact verified for you'),
      findsNothing,
    );
  });

  testWidgets('copy uses exact fingerprint value', (tester) async {
    const peerHex = 'AaBbCcDdEeFf00112233445566778899';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<dynamic, dynamic>?;
          copied = args?['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SafetyNumberScreen(
          peerEmail: 'bob@example.test',
          peerFingerprintHex: peerHex,
          localFingerprintHex: '00112233445566778899aabbccddeeff',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Copy their number'));
    await tester.tap(find.text('Copy their number'));
    await tester.pump();

    expect(copied, peerHex);
    expect(copied, isNot(formatSafetyFingerprintHex(peerHex)));
  });

  testWidgets('missing peer fingerprint disables mark verified', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SafetyNumberScreen(
          peerEmail: 'bob@example.test',
          peerFingerprintHex: '',
          localFingerprintHex: '00112233445566778899aabbccddeeff',
        ),
      ),
    );

    expect(
      find.textContaining('isn’t available right now'),
      findsOneWidget,
    );
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Mark as verified'),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('Status: Not verified'), findsOneWidget);
  });
}
