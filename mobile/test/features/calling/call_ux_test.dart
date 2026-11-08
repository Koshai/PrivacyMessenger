import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/call_platform.dart';
import 'package:private_messenger/features/calling/call_screens.dart';
import 'package:private_messenger/features/calling/call_user_copy.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';

CallController _controller({
  FakeCallService? media,
  Future<bool> Function(CallMediaType)? permissions,
}) {
  return CallController(
    api: CallingApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/hangup') ||
            request.url.path.endsWith('/cancel') ||
            request.url.path.endsWith('/decline')) {
          return http.Response(
            jsonEncode({
              'id': 'c1',
              'caller_user_id': 'alice',
              'callee_user_id': 'bob',
              'caller_device_id': 'device-a',
              'state': 'ended',
              'media_type': 'audio',
              'client_call_id': 'client-c1',
              'ring_expires_at': '2026-01-01T00:01:00Z',
              'created_at': '2026-01-01T00:00:00Z',
              'updated_at': '2026-01-01T00:00:00Z',
              'version': 1,
            }),
            200,
          );
        }
        if (request.url.path == '/calls/active') {
          return http.Response(jsonEncode({'call': null}), 200);
        }
        return http.Response(jsonEncode({'candidates': []}), 200);
      }),
      baseUri: Uri.parse('http://example.test'),
    ),
    media: media ?? FakeCallService(),
    myUserId: 'alice',
    tokenProvider: () => 'tok',
    requestPermissions: permissions ?? ((_) async => true),
  );
}

CallSession _session({
  CallMediaType media = CallMediaType.audio,
  CallRemoteState state = CallRemoteState.ringing,
}) {
  return CallSession(
    id: 'c1',
    callerUserId: 'alice',
    calleeUserId: 'bob',
    callerDeviceId: 'device-a',
    mediaType: media,
    state: state,
    clientCallId: 'client-c1',
    ringExpiresAt: DateTime.utc(2026, 1, 1, 0, 1),
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
    version: 1,
  );
}

Future<void> _drainEndedHold(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1700));
}

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
    final controller = _controller();
    controller.onLifecycle = kinds.add;
    controller.phase = CallPhase.incomingRinging;
    controller.notifyListeners();
    controller.phase = CallPhase.connected;
    controller.notifyListeners();
    controller.phase = CallPhase.ended;
    controller.notifyListeners();
    expect(kinds, ['incoming', 'ongoing', 'ended']);
  });

  test('user-facing errors hide cryptographic jargon', () {
    final controller = _controller();
    controller.error = 'DTLS fingerprint changed';
    expect(callUserFacingError(controller), isNot(contains('DTLS')));
    expect(callUserFacingError(controller), contains('secured'));

    controller.error = 'peer hello timeout';
    expect(
      callUserFacingError(controller)!.toLowerCase(),
      isNot(contains('peer hello')),
    );

    controller.error = 'Microphone permission denied';
    controller.lastRequestedMediaType = CallMediaType.audio;
    expect(isCallPermissionFailure(controller), isTrue);
    expect(callUserFacingError(controller), contains('Microphone'));
  });

  test('connected copy never claims Connected before authentication', () {
    final controller = _controller();
    controller.phase = CallPhase.connected;
    controller.authPhase = CallAuthPhase.verifying;
    final copy = callStatusCopy(controller);
    expect(copy.title, 'Securing call…');
    expect(copy.title.toLowerCase(), isNot(contains('connected')));

    controller.authPhase = CallAuthPhase.authenticated;
    controller.linkQuality = 'good';
    controller.connectedAt = DateTime.now().toUtc();
    final authCopy = callStatusCopy(controller);
    expect(authCopy.subtitle, contains('Connection good'));
  });

  testWidgets('incoming and connected screens expose controls', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.phase = CallPhase.incomingRinging;
    await tester.pumpWidget(
      MaterialApp(home: ActiveCallScreen(controller: controller)),
    );
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(find.text('Incoming call'), findsOneWidget);

    controller.phase = CallPhase.connected;
    controller.authPhase = CallAuthPhase.authenticated;
    controller.linkQuality = 'good';
    controller.session = _session(state: CallRemoteState.connected);
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('Mute'), findsOneWidget);
    expect(find.text('Hang up'), findsOneWidget);
    expect(find.textContaining('Connection good'), findsOneWidget);
  });

  testWidgets('CallHost overlays a pushed conversation route', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
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
                      builder: (_) =>
                          const Scaffold(body: Text('conversation')),
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

  testWidgets('Android back during outgoing ringing cancels once', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.phase = CallPhase.outgoingRinging;
    controller.session = _session();
    await tester.pumpWidget(
      MaterialApp(home: ActiveCallScreen(controller: controller)),
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    await _drainEndedHold(tester);
    expect(controller.phase, CallPhase.idle);
  });

  testWidgets('Android back during active call cancel keeps call', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.phase = CallPhase.connected;
    controller.authPhase = CallAuthPhase.authenticated;
    controller.session = _session(state: CallRemoteState.connected);
    await tester.pumpWidget(
      MaterialApp(home: ActiveCallScreen(controller: controller)),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('End call?'), findsOneWidget);
    await tester.tap(find.text('Stay on call'));
    await tester.pumpAndSettle();
    expect(controller.phase, CallPhase.connected);
  });

  testWidgets('Android back confirm hangs up once', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.phase = CallPhase.connected;
    controller.authPhase = CallAuthPhase.authenticated;
    controller.session = _session(state: CallRemoteState.connected);
    await tester.pumpWidget(
      MaterialApp(home: ActiveCallScreen(controller: controller)),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('End call?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Hang up'));
    await tester.pump();
    expect(controller.phase, CallPhase.ended);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(controller.phase, anyOf(CallPhase.ended, CallPhase.idle));
    await _drainEndedHold(tester);
    expect(controller.phase, CallPhase.idle);
  });

  testWidgets('failed authentication never shows authenticated chrome', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.phase = CallPhase.connected;
    controller.authPhase = CallAuthPhase.failed;
    controller.error = 'Verification failed';
    controller.session = _session(media: CallMediaType.video);
    await tester.pumpWidget(
      MaterialApp(home: ActiveCallScreen(controller: controller)),
    );
    expect(find.text('Verification failed'), findsWidgets);
    expect(find.textContaining('Device authenticated'), findsNothing);
    expect(controller.remoteMediaAuthenticated, isFalse);
  });

  testWidgets('local preview shows after auth when camera enabled', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.phase = CallPhase.connected;
    controller.authPhase = CallAuthPhase.authenticated;
    controller.cameraEnabled = true;
    controller.session = _session(
      media: CallMediaType.video,
      state: CallRemoteState.connected,
    );
    await tester.pumpWidget(
      MaterialApp(home: ActiveCallScreen(controller: controller)),
    );
    expect(find.text('You'), findsOneWidget);

    controller.cameraEnabled = false;
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('No preview'), findsOneWidget);
    expect(find.text('You'), findsNothing);
  });

  testWidgets('permission failure shows Open settings', (tester) async {
    final controller = _controller(permissions: (_) async => false);
    addTearDown(controller.dispose);
    controller.phase = CallPhase.failed;
    controller.permissionFailure = true;
    controller.error = 'Permission denied';
    controller.lastRequestedMediaType = CallMediaType.video;
    await tester.pumpWidget(
      MaterialApp(home: ActiveCallScreen(controller: controller)),
    );
    expect(find.text('Open settings'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(
      find.textContaining('Microphone and camera access'),
      findsWidgets,
    );
  });

  testWidgets('refreshPermissionFailure clears failed state when granted', (
    tester,
  ) async {
    var allow = false;
    final controller = _controller(permissions: (_) async => allow);
    addTearDown(controller.dispose);
    controller.phase = CallPhase.failed;
    controller.permissionFailure = true;
    controller.error = 'Permission denied';
    controller.lastRequestedMediaType = CallMediaType.audio;

    allow = true;
    await controller.refreshPermissionFailure();
    expect(controller.phase, CallPhase.idle);
    expect(controller.permissionFailure, isFalse);
    expect(controller.error, isNull);
  });

  testWidgets('call controls expose semantics labels', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.phase = CallPhase.connected;
    controller.authPhase = CallAuthPhase.authenticated;
    controller.session = _session(state: CallRemoteState.connected);
    await tester.pumpWidget(
      MaterialApp(home: ActiveCallScreen(controller: controller)),
    );
    expect(find.bySemanticsLabel('Hang up'), findsWidgets);
    expect(find.bySemanticsLabel('Mute'), findsWidgets);
  });

  testWidgets('large text scale keeps hang up visible on incoming', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.phase = CallPhase.incomingRinging;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
        child: MaterialApp(home: ActiveCallScreen(controller: controller)),
      ),
    );
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
  });

  testWidgets('dismiss failed call returns to idle once', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.phase = CallPhase.failed;
    controller.error = 'Connection failed';
    await tester.pumpWidget(
      MaterialApp(home: ActiveCallScreen(controller: controller)),
    );
    expect(find.text('Close'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(controller.phase, CallPhase.idle);
    expect(find.text('Close'), findsNothing);
    controller.dismissFailedCall();
    expect(controller.phase, CallPhase.idle);
  });
}
