import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/messaging/safety_number_screen.dart';

void main() {
  testWidgets('shows key-change warning and trust transitions', (tester) async {
    SafetyTrustState? latest;
    await tester.pumpWidget(
      MaterialApp(
        home: SafetyNumberScreen(
          peerEmail: 'bob@example.test',
          peerFingerprintHex: 'aabbccddeeff00112233445566778899',
          localFingerprintHex: '00112233445566778899aabbccddeeff',
          initialTrust: SafetyTrustState.changed,
          onTrustChanged: (s) => latest = s,
        ),
      ),
    );

    expect(find.textContaining('Safety number changed'), findsOneWidget);
    await tester.tap(find.text('Mark as verified'));
    await tester.pump();
    expect(latest, SafetyTrustState.verified);
    expect(find.textContaining('Trust state: verified'), findsOneWidget);
  });
}
