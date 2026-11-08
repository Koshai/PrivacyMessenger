import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/call_screens.dart';
import 'package:private_messenger/features/calling/call_user_copy.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';

CallController _controller({FakeCallService? media}) {
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
        return http.Response(jsonEncode({'call': null}), 200);
      }),
      baseUri: Uri.parse('http://example.test'),
    ),
    media: media ?? FakeCallService(),
    myUserId: 'alice',
    tokenProvider: () => 'tok',
    requestPermissions: (_) async => true,
  );
}

CallSession _session({
  CallMediaType media = CallMediaType.audio,
  CallRemoteState state = CallRemoteState.connected,
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

void main() {
  test('remote media gate requires authenticated authPhase', () {
    final c = _controller();
    addTearDown(c.dispose);
    c.phase = CallPhase.connected;
    c.authPhase = CallAuthPhase.verifying;
    expect(c.remoteMediaAuthenticated, isFalse);
    c.authPhase = CallAuthPhase.authenticated;
    expect(c.remoteMediaAuthenticated, isTrue);
  });

  test('phase copy never exposes ICE/DTLS/MLS jargon', () {
    final c = _controller();
    addTearDown(c.dispose);
    for (final phase in CallPhase.values) {
      c.phase = phase;
      c.authPhase = CallAuthPhase.verifying;
      c.error = 'DTLS fingerprint changed peer hello ICE candidate MLS epoch';
      final copy = callStatusCopy(c);
      final blob = '${copy.title} ${copy.subtitle ?? ''}'.toLowerCase();
      expect(blob, isNot(contains('dtls')));
      expect(blob, isNot(contains('ice candidate')));
      expect(blob, isNot(contains('mls epoch')));
      expect(blob, isNot(contains('peer hello')));
    }
  });

  test('cleanup clears authentication state for the next call', () async {
    final media = FakeCallService();
    final c = _controller(media: media);
    addTearDown(c.dispose);
    c.session = _session();
    c.phase = CallPhase.connected;
    c.authPhase = CallAuthPhase.authenticated;
    c.peerFingerprintHex = 'aabbccdd';
    c.authenticatedPeerDeviceId = 'peer-device';
    c.peerManuallyVerified = true;
    c.localMediaConnected = true;

    await c.hangUp();
    expect(c.authPhase, CallAuthPhase.idle);
    expect(c.peerFingerprintHex, isNull);
    expect(c.authenticatedPeerDeviceId, isNull);
    expect(c.peerManuallyVerified, isFalse);
    expect(c.remoteMediaAuthenticated, isFalse);
    expect(media.disposeCount, 1);

    await c.hangUp();
    expect(media.disposeCount, 1, reason: 'duplicate hangUp must not re-dispose');
  });

  test('failed call dismiss returns idle without leftover auth', () async {
    final c = _controller();
    addTearDown(c.dispose);
    c.phase = CallPhase.failed;
    c.authPhase = CallAuthPhase.failed;
    c.error = 'auth failed';
    c.session = _session();
    c.dismissFailedCall();
    expect(c.phase, CallPhase.idle);
    expect(c.session, isNull);
    // Auth is reset on cleanup paths; dismiss of failed screen clears session.
    expect(c.remoteMediaAuthenticated, isFalse);
  });

  testWidgets('camera-off after auth hides live local preview label', (
    tester,
  ) async {
    final c = _controller();
    addTearDown(c.dispose);
    c.session = _session(media: CallMediaType.video);
    c.phase = CallPhase.connected;
    c.authPhase = CallAuthPhase.authenticated;
    c.cameraEnabled = false;
    await tester.pumpWidget(
      MaterialApp(home: ActiveCallScreen(controller: c)),
    );
    await tester.pump();
    expect(find.text('No preview'), findsOneWidget);
    expect(find.textContaining('Connected'), findsNothing);
  });

  testWidgets('video connected before auth does not show verified chrome', (
    tester,
  ) async {
    final c = _controller();
    addTearDown(c.dispose);
    c.session = _session(media: CallMediaType.video);
    c.phase = CallPhase.connected;
    c.authPhase = CallAuthPhase.verifying;
    await tester.pumpWidget(
      MaterialApp(home: ActiveCallScreen(controller: c)),
    );
    await tester.pump();
    expect(find.textContaining('Securing call'), findsWidgets);
    expect(find.textContaining('Safety number verified'), findsNothing);
    expect(find.text('Compare safety number'), findsNothing);
  });
}
