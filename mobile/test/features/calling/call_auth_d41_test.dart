import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_auth_session.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';

const _call = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _otherCall = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _alice = '11111111-1111-4111-8111-111111111111';
const _bob = '22222222-2222-4222-8222-222222222222';
const _aliceDev = '33333333-3333-4333-8333-333333333333';
const _bobDev = '44444444-4444-4444-8444-444444444444';

Uint8List _fill(int n, int v) => Uint8List(n)..fillRange(0, n, v);

void main() {
  test('rejects a substituted hello that is valid for another call', () async {
    final algo = Ed25519();
    final keys = await algo.newKeyPair();
    final pub = (await keys.extractPublicKey()).bytes;
    final nonce = _fill(32, 7);
    final mls = _fill(32, 4);
    final foreign = helloBytes(
      callId: _otherCall,
      userId: _bob,
      deviceId: _bobDev,
      role: 2,
      nonce: nonce,
      callKey: pub,
      mls: mls,
    );
    final sig = await algo.sign(foreign, keyPair: keys);
    final check = await verifyPeerHello(
      callId: _otherCall,
      userId: _bob,
      deviceId: _bobDev,
      role: 2,
      nonce: nonce,
      callKey: pub,
      mls: mls,
      signature: sig.bytes,
      expectedCallId: _call,
      expectedUserId: _bob,
      expectedDeviceId: _bobDev,
      expectedRole: 2,
    );
    expect(check.failure, CallAuthFailure.mismatch);

    final forged = await verifyPeerHello(
      callId: _call,
      userId: _bob,
      deviceId: _bobDev,
      role: 2,
      nonce: nonce,
      callKey: pub,
      mls: mls,
      signature: sig.bytes,
      expectedCallId: _call,
      expectedUserId: _bob,
      expectedDeviceId: _bobDev,
      expectedRole: 2,
    );
    expect(forged.failure, CallAuthFailure.badSignature);
  });

  test('hello checks reject replay, bad fields, and a replacement key', () async {
    final algo = Ed25519();
    final keys = await algo.newKeyPair();
    final pub = (await keys.extractPublicKey()).bytes;
    final nonce = _fill(32, 3);
    final mls = _fill(32, 5);
    final msg = helloBytes(
      callId: _call,
      userId: _bob,
      deviceId: _bobDev,
      role: 2,
      nonce: nonce,
      callKey: pub,
      mls: mls,
    );
    final sig = (await algo.sign(msg, keyPair: keys)).bytes;
    final ok = await verifyPeerHello(
      callId: _call,
      userId: _bob,
      deviceId: _bobDev,
      role: 2,
      nonce: nonce,
      callKey: pub,
      mls: mls,
      signature: sig,
      expectedCallId: _call,
      expectedUserId: _bob,
      expectedDeviceId: _bobDev,
      expectedRole: 2,
    );
    expect(ok.ok, isTrue);

    final replay = await verifyPeerHello(
      callId: _call,
      userId: _bob,
      deviceId: _bobDev,
      role: 2,
      nonce: nonce,
      callKey: pub,
      mls: mls,
      signature: sig,
      expectedCallId: _call,
      expectedUserId: _bob,
      expectedDeviceId: _bobDev,
      expectedRole: 2,
      seenNonces: {_hex(nonce)},
    );
    expect(replay.failure, CallAuthFailure.replay);

    final swappedRole = await verifyPeerHello(
      callId: _call,
      userId: _bob,
      deviceId: _bobDev,
      role: 1,
      nonce: nonce,
      callKey: pub,
      mls: mls,
      signature: sig,
      expectedCallId: _call,
      expectedUserId: _bob,
      expectedDeviceId: _bobDev,
      expectedRole: 2,
    );
    expect(swappedRole.failure, isNot(CallAuthFailure.none));

    final other = await algo.newKeyPair();
    final otherPub = (await other.extractPublicKey()).bytes;
    final replaced = await verifyPeerHello(
      callId: _call,
      userId: _bob,
      deviceId: _bobDev,
      role: 2,
      nonce: nonce,
      callKey: pub,
      mls: mls,
      signature: sig,
      expectedCallId: _call,
      expectedUserId: _bob,
      expectedDeviceId: _bobDev,
      expectedRole: 2,
      pinnedCallKey: otherPub,
    );
    expect(replaced.failure, CallAuthFailure.unexpectedKey);

    final malformed = await verifyPeerHello(
      callId: _call,
      userId: _bob,
      deviceId: _bobDev,
      role: 2,
      nonce: _fill(8, 1),
      callKey: pub,
      mls: mls,
      signature: sig,
      expectedCallId: _call,
      expectedUserId: _bob,
      expectedDeviceId: _bobDev,
      expectedRole: 2,
    );
    expect(malformed.failure, CallAuthFailure.malformed);
  });

  test('binding rejects a server fingerprint that is not the pinned identity', () async {
    final algo = Ed25519();
    final keys = await algo.newKeyPair();
    final pub = (await keys.extractPublicKey()).bytes;
    final pinnedMls = _fill(32, 9);
    final claimedMls = _fill(32, 8);
    final statement = bindingStatementBytes(
      userId: _bob,
      deviceId: _bobDev,
      callKey: pub,
      mls: claimedMls,
    );
    final sig = (await algo.sign(statement, keyPair: keys)).bytes;
    final check = await verifyCallKeyBinding(
      statement: statement,
      signature: sig,
      expectedUserId: _bob,
      expectedDeviceId: _bobDev,
      helloCallKey: pub,
      pinnedMlsHex: _hex(pinnedMls),
    );
    expect(check.failure, CallAuthFailure.unexpectedKey);

    final matching = bindingStatementBytes(
      userId: _bob,
      deviceId: _bobDev,
      callKey: pub,
      mls: pinnedMls,
    );
    final matchingSig = (await algo.sign(matching, keyPair: keys)).bytes;
    final ok = await verifyCallKeyBinding(
      statement: matching,
      signature: matchingSig,
      expectedUserId: _bob,
      expectedDeviceId: _bobDev,
      helloCallKey: pub,
      pinnedMlsHex: _hex(pinnedMls),
    );
    expect(ok.ok, isTrue);

    final replacedDevice = await verifyCallKeyBinding(
      statement: matching,
      signature: matchingSig,
      expectedUserId: _bob,
      expectedDeviceId: _bobDev,
      helloCallKey: pub,
      pinnedMlsHex: _hex(pinnedMls),
      pinnedDeviceForUser: _aliceDev,
    );
    expect(replacedDevice.failure, CallAuthFailure.unexpectedKey);
  });

  test('session rejects a signaling server that substitutes another valid hello', () async {
    final outcome = await _runSession(
      helloCallId: _otherCall,
      enrolled: true,
    );
    expect(outcome.phase, CallAuthPhase.failed);
  });

  test('session accepts a hello whose binding matches the pinned identity', () async {
    final outcome = await _runSession(helloCallId: _call, enrolled: true, complete: true);
    expect(outcome.phase, CallAuthPhase.authenticated);
    expect(outcome.manuallyVerified, isFalse);
  });

  test('session fails closed when the enrolled device is revoked', () async {
    final outcome = await _runSession(helloCallId: _call, enrolled: false);
    expect(outcome.error, 'Identity revoked');
  });

  test('a missing enrollment check fails closed', () async {
    final outcome = await _runSession(
      helloCallId: _call,
      enrolled: true,
      omitEnrollment: true,
    );
    expect(outcome.phase, CallAuthPhase.failed);
    expect(outcome.error, contains('Enrollment'));
  });

  test('missing authenticator does not present remote media as authenticated', () async {
    final media = FakeCallService();
    var hungUp = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/hangup')) {
        hungUp = true;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      if (request.url.path.endsWith('/connected')) {
        return http.Response(jsonEncode(_sessionJson(state: 'connected')), 200);
      }
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': _sessionJson()}), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = CallController(
      api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
      media: media,
      myUserId: _alice,
      tokenProvider: () => 'tok',
    );
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_sessionJson());
    await controller.startListening();
    expect(controller.remoteMediaAuthenticated, isFalse);
    media.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(hungUp, isTrue);
    expect(controller.remoteMediaAuthenticated, isFalse);
    expect(media.remotePlayback, isFalse);
  });

  test('fingerprint change and peer-connection replacement end the call', () async {
    final media = FakeCallService();
    var hungUp = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/hangup')) {
        hungUp = true;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      if (request.url.path.endsWith('/connected')) {
        return http.Response(jsonEncode(_sessionJson(state: 'connected')), 200);
      }
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': _sessionJson()}), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = CallController(
      api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
      media: media,
      myUserId: _alice,
      tokenProvider: () => 'tok',
      authenticatePeer: (_) async => const CallAuthOutcome(
        phase: CallAuthPhase.authenticated,
        fingerprintHex: 'abc',
      ),
    );
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_sessionJson());
    await controller.startListening();
    media.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(controller.remoteMediaAuthenticated, isTrue);
    expect(media.remotePlayback, isTrue);

    await media.applyRemoteAnswer('v=0\r\nsame');
    expect(hungUp, isFalse);

    media.remoteDtls = _fill(32, 9);
    await media.applyRemoteAnswer('v=0\r\nrenegotiated');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(hungUp, isTrue);
    expect(controller.remoteMediaAuthenticated, isFalse);
  });

  test('replacing the peer connection invalidates authentication', () async {
    final media = FakeCallService();
    var hungUp = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/hangup')) {
        hungUp = true;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      if (request.url.path.endsWith('/connected')) {
        return http.Response(jsonEncode(_sessionJson(state: 'connected')), 200);
      }
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': _sessionJson()}), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = CallController(
      api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
      media: media,
      myUserId: _alice,
      tokenProvider: () => 'tok',
      authenticatePeer: (_) async =>
          const CallAuthOutcome(phase: CallAuthPhase.authenticated),
    );
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_sessionJson());
    await controller.startListening();
    media.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    media.replacePeerConnection();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(hungUp, isTrue);
    expect(controller.authPhase, isNot(CallAuthPhase.authenticated));
  });
}

Future<CallAuthOutcome> _runSession({
  required String helloCallId,
  required bool enrolled,
  bool complete = false,
  bool omitEnrollment = false,
}) async {
  final algo = Ed25519();
  final peer = await algo.newKeyPair();
  final peerPub = (await peer.extractPublicKey()).bytes;
  final peerNonce = _fill(32, 6);
  final mls = _fill(32, 4);
  final hello = helloBytes(
    callId: helloCallId,
    userId: _bob,
    deviceId: _bobDev,
    role: 2,
    nonce: peerNonce,
    callKey: peerPub,
    mls: mls,
  );
  final helloSig = (await algo.sign(hello, keyPair: peer)).bytes;
  final statement = bindingStatementBytes(
    userId: _bob,
    deviceId: _bobDev,
    callKey: peerPub,
    mls: mls,
  );
  final bindingSig = (await algo.sign(statement, keyPair: peer)).bytes;
  List<int>? localNonce;
  List<int>? localKey;
  var confirmPosted = false;
  final store = MemoryCallAuthStore();
  final session = CallAuthSession(
    api: CallingApiClient(
      client: MockClient((request) async {
        if (request.url.path == '/calls/auth-key') {
          return http.Response('', 204);
        }
        if (request.method == 'POST' && request.url.path.endsWith('/auth')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['kind'] == 'hello') {
            localNonce = base64Decode(body['nonce_b64'] as String);
            localKey = base64Decode(body['call_public_key_b64'] as String);
          }
          if (body['kind'] == 'confirm') confirmPosted = true;
          return http.Response('{}', 200);
        }
        final frames = <Map<String, dynamic>>[
          {
            'kind': 'hello',
            'call_id': helloCallId,
            'sender_user_id': _bob,
            'sender_device_id': _bobDev,
            'role': 2,
            'nonce_b64': base64Encode(peerNonce),
            'call_public_key_b64': base64Encode(peerPub),
            'mls_fingerprint_hex': _hex(mls),
            'signature_b64': base64Encode(helloSig),
          },
        ];
        if (complete && confirmPosted && localNonce != null && localKey != null) {
          final transcript = CallTranscript(
            callId: _call,
            callerUser: _alice,
            calleeUser: _bob,
            callerDevice: _aliceDev,
            calleeDevice: _bobDev,
            mediaAudio: true,
            callerNonce: localNonce!,
            calleeNonce: peerNonce,
            callerDtls: _fill(32, 1),
            calleeDtls: _fill(32, 2),
            callerMls: _fill(32, 1),
            calleeMls: mls,
            callerCallKey: localKey!,
            calleeCallKey: peerPub,
          );
          final confirmSig = await algo.sign(transcript.bytes(), keyPair: peer);
          frames.add({
            'kind': 'confirm',
            'sender_device_id': _bobDev,
            'signature_b64': base64Encode(confirmSig.bytes),
          });
        }
        return http.Response(jsonEncode({'frames': frames}), 200);
      }),
      baseUri: Uri.parse('http://example.test'),
    ),
    token: () => 'tok',
    userId: _alice,
    deviceId: _aliceDev,
    localMlsFingerprintHex: _hex(_fill(32, 1)),
    store: store,
    deviceStillEnrolled: omitEnrollment ? null : (peerUser, peerDevice) async => enrolled,
    bindingExchange: ({
      required peerUserId,
      required peerDeviceId,
      required localStatement,
      required localSignature,
    }) async {
      return PeerBinding(statement: statement, signature: bindingSig);
    },
  );
  return session.run(CallAuthRequest(
    session: CallSession.fromJson(_sessionJson()),
    myUserId: _alice,
    localDtls: _fill(32, 1),
    remoteDtls: _fill(32, 2),
  ));
}

Map<String, dynamic> _sessionJson({String state = 'accepted'}) => {
      'id': _call,
      'caller_user_id': _alice,
      'callee_user_id': _bob,
      'caller_device_id': _aliceDev,
      'callee_device_id': _bobDev,
      'media_type': 'audio',
      'state': state,
      'client_call_id': 'c1',
      'ring_expires_at': DateTime.now().toUtc().add(const Duration(minutes: 1)).toIso8601String(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'version': 1,
    };

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
