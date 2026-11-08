import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/core/ui/app_empty_state.dart';
import 'package:private_messenger/core/ui/app_error_panel.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/call_screens.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';
import 'package:private_messenger/main.dart';

CallController _controller() {
  return CallController(
    api: CallingApiClient(
      client: MockClient((request) async {
        return http.Response(jsonEncode({'call': null}), 200);
      }),
      baseUri: Uri.parse('http://example.test'),
    ),
    media: FakeCallService(),
    myUserId: 'alice',
    tokenProvider: () => 'tok',
    requestPermissions: (_) async => true,
  );
}

void main() {
  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('main tabs remain usable at text scale $scale', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: const MaterialApp(home: MainNavigation()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Chats'), findsWidgets);
      expect(find.text('Add friends'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('error panel primary action reachable at scale $scale', (
      tester,
    ) async {
      var tapped = 0;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: MaterialApp(
            home: Scaffold(
              body: AppErrorPanel(
                title: 'Something went wrong',
                message: 'A longer explanation that should wrap safely '
                    'without hiding the retry control under large text.',
                primaryLabel: 'Retry',
                onPrimary: () => tapped++,
                secondaryLabel: 'Cancel',
                onSecondary: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Retry'));
      await tester.tap(find.text('Retry'));
      expect(tapped, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty state CTA reachable at scale $scale', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: MaterialApp(
            home: Scaffold(
              body: AppEmptyState(
                icon: Icons.chat_bubble_outline,
                title: 'No conversations yet',
                message: 'Add a friend from the Friends tab, then open their '
                    'chat here to send encrypted messages or start a call.',
                actionLabel: 'Add friends',
                onAction: () => tapped++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add friends'));
      await tester.tap(find.text('Add friends'));
      expect(tapped, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('call hang-up remains labeled at large text', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.session = CallSession(
      id: 'c1',
      callerUserId: 'alice',
      calleeUserId: 'bob',
      callerDeviceId: 'device-a',
      mediaType: CallMediaType.audio,
      state: CallRemoteState.connected,
      clientCallId: 'client-c1',
      ringExpiresAt: DateTime.utc(2026, 1, 1, 0, 1),
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      version: 1,
    );
    controller.phase = CallPhase.connected;
    controller.authPhase = CallAuthPhase.authenticated;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: MaterialApp(
          home: ActiveCallScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('Hang up'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
