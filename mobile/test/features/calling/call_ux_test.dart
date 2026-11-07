import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/call_platform.dart';
import 'package:private_messenger/features/calling/call_screens.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'dart:convert';

void main() {
  test('notification copy has no signaling or identity payload', () {
    expect(CallPlatformBridge.bodyFor('incoming'), 'Incoming call');
    expect(CallPlatformBridge.bodyFor('ongoing'), 'Call in progress');
    for (final kind in ['incoming', 'ongoing', 'ended']) {
      final text = CallPlatformBridge.bodyFor(kind);
      expect(text.contains('sdp'), isFalse);
      expect(text.contains('token'), isFalse);
      expect(text.contains('@'), isFalse);
    }
  });

  test('lifecycle signals are kinds, not call records', () async {
    final kinds = <String>[];
    final media = FakeCallService();
    final controller = CallController(
      api: CallingApiClient(
        client: MockClient((request) async {
          if (request.url.path == '/calls/active') {
            return http.Response(jsonEncode({'call': null}), 200);
          }
          return http.Response(jsonEncode({'candidates': []}), 200);
        }),
        baseUri: Uri.parse('http://example.test'),
      ),
      media: media,
      myUserId: 'alice',
      tokenProvider: () => 'tok',
    );
    controller.onLifecycle = kinds.add;
    controller.phase = CallPhase.incomingRinging;
    controller.notifyListeners();
    controller.phase = CallPhase.connected;
    controller.notifyListeners();
    controller.phase = CallPhase.ended;
    controller.notifyListeners();
    expect(kinds, ['incoming', 'ongoing', 'ended']);
  });

  testWidgets('incoming and connected screens expose controls', (tester) async {
    final controller = CallController(
      api: CallingApiClient(
        client: MockClient((_) async => http.Response('{}', 200)),
        baseUri: Uri.parse('http://example.test'),
      ),
      media: FakeCallService(),
      myUserId: 'alice',
      tokenProvider: () => 'tok',
    );
    controller.phase = CallPhase.incomingRinging;
    await tester.pumpWidget(MaterialApp(home: ActiveCallScreen(controller: controller)));
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(find.text('Incoming call'), findsOneWidget);

    controller.phase = CallPhase.connected;
    controller.authPhase = CallAuthPhase.authenticated;
    controller.linkQuality = 'good';
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('Mute'), findsOneWidget);
    expect(find.text('Speaker'), findsOneWidget);
    expect(find.text('Hang up'), findsOneWidget);
    expect(find.textContaining('Connection good'), findsOneWidget);
  });

  testWidgets('CallHost overlays a pushed conversation route', (tester) async {
    final controller = CallController(
      api: CallingApiClient(
        client: MockClient((_) async => http.Response('{}', 200)),
        baseUri: Uri.parse('http://example.test'),
      ),
      media: FakeCallService(),
      myUserId: 'alice',
      tokenProvider: () => 'tok',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CallHost(
          controller: controller,
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('conversation')),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('conversation'), findsOneWidget);

    controller.phase = CallPhase.outgoingRinging;
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('Calling…'), findsOneWidget);
    expect(find.text('conversation'), findsOneWidget);

    controller.phase = CallPhase.idle;
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('Calling…'), findsNothing);
  });
}
