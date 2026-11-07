import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';

void main() {
  test('a late authenticator cannot enable playback after hang-up', () async {
    final media = FakeCallService();
    final gate = Completer<CallAuthOutcome>();
    final controller = _controller(
      media,
      authenticatePeer: (_) => gate.future,
    );
    addTearDown(controller.dispose);
    await controller.startListening();
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_json(state: 'accepted'));
    media.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(media.remotePlayback, isFalse);
    await controller.hangUp();
    gate.complete(const CallAuthOutcome(phase: CallAuthPhase.authenticated));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    media.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(media.remotePlayback, isFalse);
    expect(media.disposed, isTrue);
    expect(media.disposeCount, 1);
    expect(controller.remoteMediaAuthenticated, isFalse);
  });

  test('an API interruption does not end an authenticated call', () async {
    final media = FakeCallService();
    final controller = _controller(
      media,
      recheckEnrollment: (_, _) async => throw StateError('network'),
    );
    addTearDown(controller.dispose);
    _markAuthenticated(controller);
    await controller.recheckPeerIdentity();
    expect(controller.enrollmentRecheckDeferred, isTrue);
    expect(controller.phase, CallPhase.connected);
    expect(controller.remoteMediaAuthenticated, isTrue);
    expect(media.disposed, isFalse);
  });

  test('an enrollment timeout is not treated as revocation', () async {
    final media = FakeCallService();
    final controller = _controller(
      media,
      enrollmentTimeout: const Duration(milliseconds: 30),
      recheckEnrollment: (_, _) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return false;
      },
    );
    addTearDown(controller.dispose);
    _markAuthenticated(controller);
    await controller.recheckPeerIdentity();
    expect(controller.enrollmentRecheckDeferred, isTrue);
    expect(controller.phase, CallPhase.connected);
    expect(media.disposed, isFalse);
  });

  test('a revoked identity ends the call and releases media', () async {
    final media = FakeCallService();
    final controller = _controller(media, recheckEnrollment: (_, _) async => false);
    addTearDown(controller.dispose);
    _markAuthenticated(controller);
    await controller.recheckPeerIdentity();
    expect(controller.phase, anyOf(CallPhase.ended, CallPhase.idle));
    expect(controller.remoteMediaAuthenticated, isFalse);
    expect(media.disposed, isTrue);
    expect(media.disposeCount, 1);
  });

  test('connection failure and controller disposal release media once', () async {
    final media = FakeCallService();
    final controller = _controller(media);
    addTearDown(media.close);
    await controller.startListening();
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_json(
      state: 'accepted',
      offer: 'v=0\r\noffer-fake',
      answer: 'v=0\r\nanswer-fake',
    ));
    media.emitFailed();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(media.disposeCount, 1);
    controller.dispose();
    expect(media.disposeCount, 1);
  });
}

CallController _controller(
  FakeCallService media, {
  CallAuthenticator? authenticatePeer,
  Future<bool> Function(String peerUserId, String peerDeviceId)? recheckEnrollment,
  Duration enrollmentTimeout = const Duration(seconds: 5),
}) {
  return CallController(
    api: CallingApiClient(
      client: MockClient((request) async {
        if (request.url.path == '/calls/active') {
          return http.Response(jsonEncode({'call': null}), 200);
        }
        if (request.url.path.endsWith('/hangup')) {
          return http.Response(jsonEncode(_json(state: 'ended')), 200);
        }
        if (request.url.path.endsWith('/connected')) {
          return http.Response(jsonEncode(_json(state: 'connected')), 200);
        }
        return http.Response(jsonEncode({'candidates': []}), 200);
      }),
      baseUri: Uri.parse('http://example.test'),
    ),
    media: media,
    myUserId: 'alice',
    tokenProvider: () => 'tok',
    authenticatePeer: authenticatePeer ??
        (_) async => const CallAuthOutcome(phase: CallAuthPhase.authenticated),
    recheckEnrollment: recheckEnrollment,
    enrollmentTimeout: enrollmentTimeout,
  );
}

void _markAuthenticated(CallController controller) {
  controller.phase = CallPhase.connected;
  controller.authPhase = CallAuthPhase.authenticated;
  controller.authenticatedPeerDeviceId = 'bdev';
  controller.session = CallSession.fromJson(_json(state: 'connected'));
}

Map<String, dynamic> _json({
  required String state,
  String? offer,
  String? answer,
}) =>
    {
      'id': 'call-1',
      'caller_user_id': 'alice',
      'callee_user_id': 'bob',
      'caller_device_id': 'adev',
      'callee_device_id': 'bdev',
      'media_type': 'audio',
      'state': state,
      'client_call_id': 'c1',
      'ring_expires_at': DateTime.now().toUtc().add(const Duration(minutes: 1)).toIso8601String(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'version': 1,
      'sdp_offer': ?offer,
      'sdp_answer': ?answer,
    };
