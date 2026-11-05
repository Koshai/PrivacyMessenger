import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'dart:convert';

Uint8List _b(int n, int v) => Uint8List(n)..fillRange(0, n, v);

void main() {
  test('verifies a real Ed25519 signature and rejects a swapped fingerprint', () async {
    final algo = Ed25519();
    final keys = await algo.newKeyPair();
    final pub = await keys.extractPublicKey();
    const id = '01010101-0101-4101-8101-010101010101';
    final transcript = CallTranscript(
      callId: id,
      callerUser: id,
      calleeUser: id,
      callerDevice: id,
      calleeDevice: id,
      mediaAudio: true,
      callerNonce: _b(32, 1),
      calleeNonce: _b(32, 2),
      callerDtls: _b(32, 3),
      calleeDtls: _b(32, 4),
      callerMls: _b(32, 5),
      calleeMls: _b(32, 6),
      callerCallKey: pub.bytes,
      calleeCallKey: pub.bytes,
    );
    final sig = await algo.sign(transcript.bytes(), keyPair: keys);
    final ok = await verifyPeerConfirm(
      pinnedCallKey: pub.bytes,
      observedRemoteDtls: transcript.calleeDtls,
      transcript: transcript,
      peerIsCaller: false,
      signature: sig.bytes,
    );
    expect(ok, CallAuthPhase.authenticated);

    final tampered = await verifyPeerConfirm(
      pinnedCallKey: pub.bytes,
      observedRemoteDtls: _b(32, 9),
      transcript: transcript,
      peerIsCaller: false,
      signature: sig.bytes,
    );
    expect(tampered, CallAuthPhase.failed);

    final other = await algo.newKeyPair();
    final otherPub = await other.extractPublicKey();
    final wrongKey = await verifyPeerConfirm(
      pinnedCallKey: otherPub.bytes,
      observedRemoteDtls: transcript.calleeDtls,
      transcript: transcript,
      peerIsCaller: false,
      signature: sig.bytes,
    );
    expect(wrongKey, CallAuthPhase.failed);
  });

  test('matches the Go hello test vector', () async {
    final seed = Uint8List.fromList(List.generate(32, (i) => i + 1));
    final pair = await Ed25519().newKeyPairFromSeed(seed);
    final pub = await pair.extractPublicKey();
    expect(
      pub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664',
    );
    const id = '01010101-0101-4101-8101-010101010101';
    final msg = helloBytes(
      callId: id,
      userId: id,
      deviceId: id,
      role: 1,
      nonce: _b(32, 9),
      callKey: pub.bytes,
      mls: _b(32, 4),
    );
    final sig = await Ed25519().sign(msg, keyPair: pair);
    expect(
      sig.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '89ef82abe2cc6fccf96154e39cac68f6ce97fb87dc28998caaa8642382c9314f'
      '6068205c0ceb7d778678be35f062867f2c296e209a5bcb48c252639c3b99a000',
    );
  });

  test('controller fails closed when authentication rejects the peer', () async {
    final media = FakeCallService();
    var hungUp = false;
    final client = MockClient((request) async {
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': _session()}), 200);
      }
      if (request.url.path.endsWith('/hangup')) {
        hungUp = true;
        return http.Response(jsonEncode(_session(state: 'ended')), 200);
      }
      if (request.url.path.endsWith('/connected')) {
        return http.Response(jsonEncode(_session(state: 'connected')), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = CallController(
      api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
      media: media,
      myUserId: 'alice',
      tokenProvider: () => 'tok',
      requestPermissions: (_) async => true,
      authenticatePeer: (_) async => const CallAuthOutcome(
        phase: CallAuthPhase.identityChanged,
        error: 'Identity changed',
      ),
    );
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_session());
    await controller.startListening();
    media.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(hungUp, isTrue);
    expect(controller.remoteMediaAuthenticated, isFalse);
    expect(media.disposed, isTrue);
  });

  test('controller shows authenticated only after verification', () async {
    final media = FakeCallService();
    final client = MockClient((request) async {
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': _session(state: 'accepted')}), 200);
      }
      if (request.url.path.endsWith('/connected')) {
        return http.Response(jsonEncode(_session(state: 'connected')), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = CallController(
      api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
      media: media,
      myUserId: 'alice',
      tokenProvider: () => 'tok',
      requestPermissions: (_) async => true,
      authenticatePeer: (_) async => const CallAuthOutcome(
        phase: CallAuthPhase.authenticated,
        fingerprintHex: 'abc',
        manuallyVerified: false,
      ),
    );
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_session(state: 'accepted'));
    await controller.startListening();
    expect(controller.remoteMediaAuthenticated, isFalse);
    media.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.authPhase, CallAuthPhase.authenticated);
    expect(controller.remoteMediaAuthenticated, isTrue);
    expect(controller.peerManuallyVerified, isFalse);
  });

  test('dtls restart after verification ends the call', () async {
    final media = FakeCallService();
    var hungUp = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/hangup')) {
        hungUp = true;
        return http.Response(jsonEncode(_session(state: 'ended')), 200);
      }
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': _session(state: 'accepted')}), 200);
      }
      if (request.url.path.endsWith('/connected')) {
        return http.Response(jsonEncode(_session(state: 'connected')), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = CallController(
      api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
      media: media,
      myUserId: 'alice',
      tokenProvider: () => 'tok',
      requestPermissions: (_) async => true,
      authenticatePeer: (_) async => const CallAuthOutcome(phase: CallAuthPhase.authenticated),
    );
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_session(state: 'accepted'));
    await controller.startListening();
    media.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await controller.onDtlsRestart(List<int>.filled(32, 9));
    expect(hungUp, isTrue);
  });
}

Map<String, dynamic> _session({String state = 'accepted'}) => {
      'id': 'call-1',
      'caller_user_id': 'alice',
      'callee_user_id': 'bob',
      'caller_device_id': 'adev',
      'media_type': 'audio',
      'state': state,
      'client_call_id': 'c1',
      'ring_expires_at': DateTime.now().toUtc().add(const Duration(minutes: 1)).toIso8601String(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'version': 1,
    };
