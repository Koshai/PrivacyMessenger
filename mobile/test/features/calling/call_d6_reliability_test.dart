import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_auth_session.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';

class _ThrowingStore implements CallAuthStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {
    throw StateError('secure storage unavailable');
  }

  @override
  Future<void> delete(String key) async {}
}

void main() {
  final fingerprint = 'ab' * 32;
  final other = 'cd' * 32;

  test('a missing messaging pin is written and kept across reads', () async {
    final store = MemoryCallAuthStore();
    await persistMessagingDevicePin('dev-1', fingerprint, store: store);
    expect(store.values['call_auth_mls_dev-1'], fingerprint);
    await persistMessagingDevicePin('dev-1', fingerprint.toUpperCase(), store: store);
    expect(store.values['call_auth_mls_dev-1'], fingerprint);
  });

  test('a different messaging pin is an identity-change error and is not overwritten', () async {
    final store = MemoryCallAuthStore()..values['call_auth_mls_dev-1'] = fingerprint;
    await expectLater(
      persistMessagingDevicePin('dev-1', other, store: store),
      throwsA(isA<IdentityPinConflict>()),
    );
    expect(store.values['call_auth_mls_dev-1'], fingerprint);
  });

  test('a corrupt messaging pin fails closed', () async {
    final store = MemoryCallAuthStore()..values['call_auth_mls_dev-1'] = 'zz';
    await expectLater(
      persistMessagingDevicePin('dev-1', fingerprint, store: store),
      throwsA(isA<IdentityPinConflict>().having((e) => e.message, 'message', contains('corrupt'))),
    );
    expect(store.values['call_auth_mls_dev-1'], 'zz');
  });

  test('a failed pin write propagates', () async {
    await expectLater(
      persistMessagingDevicePin('dev-1', fingerprint, store: _ThrowingStore()),
      throwsA(isA<StateError>()),
    );
  });

  test('logout clears the local call seed and leaves contact pins', () async {
    final store = MemoryCallAuthStore()
      ..values['call_auth_seed_user_dev'] = 'seed'
      ..values['call_auth_mls_peer'] = fingerprint;
    await clearLocalCallSecret(userId: 'user', deviceId: 'dev', store: store);
    expect(store.values.containsKey('call_auth_seed_user_dev'), isFalse);
    expect(store.values['call_auth_mls_peer'], fingerprint);
  });

  test('audio and video calls gate media, honor controls, and release both sides', () async {
    for (final mediaName in ['audio', 'video']) {
      final hintsForAlice = StreamController<Map<String, dynamic>>.broadcast();
      final hintsForBob = StreamController<Map<String, dynamic>>.broadcast();
      var created = false;
      var state = 'ringing';
      String? offer;
      String? answer;
      var hangups = 0;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST' && path == '/calls') {
          created = true;
          return http.Response(jsonEncode(_json(mediaName, state: state)), 201);
        }
        if (request.method == 'PUT' && path.endsWith('/offer')) {
          offer = (jsonDecode(request.body) as Map<String, dynamic>)['sdp'] as String;
          return http.Response(jsonEncode(_json(mediaName, state: state, offer: offer)), 200);
        }
        if (request.method == 'POST' && path.endsWith('/accept')) {
          state = 'accepted';
          return http.Response(jsonEncode(_json(mediaName, state: state, offer: offer)), 200);
        }
        if (request.method == 'PUT' && path.endsWith('/answer')) {
          answer = (jsonDecode(request.body) as Map<String, dynamic>)['sdp'] as String;
          return http.Response(
            jsonEncode(_json(mediaName, state: state, offer: offer, answer: answer)),
            200,
          );
        }
        if (request.method == 'POST' && path.endsWith('/connected')) {
          state = 'connected';
          return http.Response(
            jsonEncode(_json(mediaName, state: state, offer: offer, answer: answer)),
            200,
          );
        }
        if (request.method == 'POST' && path.endsWith('/hangup')) {
          hangups++;
          state = 'ended';
          offer = null;
          answer = null;
          return http.Response(jsonEncode(_json(mediaName, state: 'ended')), 200);
        }
        if (path == '/calls/active') {
          if (!created || state == 'ended') return http.Response(jsonEncode({'call': null}), 200);
          return http.Response(
            jsonEncode({'call': _json(mediaName, state: state, offer: offer, answer: answer)}),
            200,
          );
        }
        if (path == '/calls/call-1') {
          return http.Response(
            jsonEncode(_json(mediaName, state: state, offer: offer, answer: answer)),
            200,
          );
        }
        if (path.endsWith('/ice')) return http.Response(jsonEncode({'candidates': []}), 200);
        return http.Response('nope', 404);
      });

      CallController build(String me, Stream<Map<String, dynamic>> hints, FakeCallService media) {
        return CallController(
          api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
          media: media,
          myUserId: me,
          tokenProvider: () => 'tok',
          hintEvents: hints,
          requestPermissions: (_) async => true,
          authenticatePeer: (_) async => const CallAuthOutcome(
            phase: CallAuthPhase.authenticated,
            peerDeviceId: 'peer',
          ),
        );
      }

      final aliceMedia = FakeCallService();
      final bobMedia = FakeCallService();
      final alice = build('alice', hintsForAlice.stream, aliceMedia);
      final bob = build('bob', hintsForBob.stream, bobMedia);
      addTearDown(() async {
        alice.dispose();
        bob.dispose();
        await hintsForAlice.close();
        await hintsForBob.close();
        await aliceMedia.close();
        await bobMedia.close();
      });

      await alice.startListening();
      await alice.startOutgoing(peerUserId: 'bob', mediaType: CallMediaType.values.byName(mediaName));
      expect(alice.phase, CallPhase.outgoingRinging);
      await alice.startOutgoing(peerUserId: 'bob', mediaType: CallMediaType.audio);
      expect(alice.phase, CallPhase.outgoingRinging, reason: 'a second call is refused');

      await bob.startListening();
      expect(bob.phase, CallPhase.incomingRinging);
      expect(bob.remoteMediaAuthenticated, isFalse);

      await bob.acceptIncoming();
      hintsForAlice.add({'type': 'call.answered', 'call_id': 'call-1'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(aliceMedia.applyAnswerCount, 1);
      expect(aliceMedia.remotePlayback, isFalse);
      hintsForAlice.add({'type': 'call.answered', 'call_id': 'call-1'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(aliceMedia.applyAnswerCount, 1, reason: 'a duplicate answer is ignored');

      aliceMedia.emitConnected();
      bobMedia.emitConnected();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(alice.remoteMediaAuthenticated, isTrue);
      expect(bob.remoteMediaAuthenticated, isTrue);
      expect(aliceMedia.remotePlayback, isTrue);
      expect(bobMedia.remotePlayback, isTrue);

      await alice.toggleMute();
      await alice.toggleSpeaker();
      await bob.toggleCamera();
      expect(aliceMedia.micMuted, isTrue);
      expect(aliceMedia.speakerOn, isTrue);
      expect(bobMedia.cameraOn, isFalse);

      await bob.hangUp();
      hintsForAlice.add({'type': 'call.ended', 'call_id': 'call-1'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(hangups, 1);
      expect(state, 'ended');
      expect(offer, isNull);
      expect(answer, isNull);
      expect(aliceMedia.disposed, isTrue);
      expect(bobMedia.disposed, isTrue);
    }
  });

  test('authentication timeout ends the call without enabling remote media', () async {
    final media = FakeCallService();
    var hung = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/hangup')) {
        hung = true;
        return http.Response(jsonEncode(_json('audio', state: 'ended')), 200);
      }
      if (request.url.path.endsWith('/connected')) {
        return http.Response(jsonEncode(_json('audio', state: 'connected')), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = CallController(
      api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
      media: media,
      myUserId: 'alice',
      tokenProvider: () => 'tok',
      authTimeout: const Duration(milliseconds: 40),
      authenticatePeer: (_) => Completer<CallAuthOutcome>().future,
    );
    addTearDown(controller.dispose);
    await controller.startListening();
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_json('audio', state: 'accepted'));
    media.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hung, isTrue);
    expect(controller.remoteMediaAuthenticated, isFalse);
    expect(media.remotePlayback, isFalse);
    expect(media.disposed, isTrue);
  });

  test('a revocation recheck ends an authenticated call', () async {
    final media = FakeCallService();
    var hung = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/hangup')) {
        hung = true;
        return http.Response(jsonEncode(_json('audio', state: 'ended')), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = CallController(
      api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
      media: media,
      myUserId: 'alice',
      tokenProvider: () => 'tok',
      recheckEnrollment: (_, _) async => false,
    );
    addTearDown(controller.dispose);
    controller.phase = CallPhase.connected;
    controller.authPhase = CallAuthPhase.authenticated;
    controller.authenticatedPeerDeviceId = 'bdev';
    controller.session = CallSession.fromJson(_json('audio', state: 'connected'));
    await controller.recheckPeerIdentity();
    expect(hung, isTrue);
    expect(controller.remoteMediaAuthenticated, isFalse);
    expect(media.disposed, isTrue);
  });

  test('logout runs local call-secret cleanup', () async {
    var cleared = false;
    final controller = CallController(
      api: CallingApiClient(
        client: MockClient((_) async => http.Response('{}', 200)),
        baseUri: Uri.parse('http://example.test'),
      ),
      media: FakeCallService(),
      myUserId: 'alice',
      tokenProvider: () => 'tok',
      clearLocalSecrets: () async {
        cleared = true;
      },
    );
    addTearDown(controller.dispose);
    await controller.onLogout();
    expect(cleared, isTrue);
  });
}

Map<String, dynamic> _json(
  String media, {
  required String state,
  String? offer,
  String? answer,
}) {
  return {
    'id': 'call-1',
    'caller_user_id': 'alice',
    'callee_user_id': 'bob',
    'caller_device_id': 'adev',
    'callee_device_id': 'bdev',
    'media_type': media,
    'state': state,
    'client_call_id': 'c1',
    'ring_expires_at': DateTime.now().toUtc().add(const Duration(minutes: 1)).toIso8601String(),
    'created_at': DateTime.now().toUtc().toIso8601String(),
    'updated_at': DateTime.now().toUtc().toIso8601String(),
    'version': 1,
    'sdp_offer': ?offer,
    'sdp_answer': ?answer,
  };
}
