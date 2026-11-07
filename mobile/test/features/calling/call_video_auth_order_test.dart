import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_auth_session.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';

const _call = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _alice = '11111111-1111-4111-8111-111111111111';
const _bob = '22222222-2222-4222-8222-222222222222';
const _aliceDev = '33333333-3333-4333-8333-333333333333';
const _bobDev = '44444444-4444-4444-8444-444444444444';

Uint8List _fill(int n, int v) => Uint8List(n)..fillRange(0, n, v);
String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('call auth publishes hello before resolving DTLS fingerprints', () async {
    // Regression: video ICE-connected peers hit peer_hello_timeout because
    // DTLS fingerprint reads blocked hello publish on one side.
    final algo = Ed25519();
    final peer = await algo.newKeyPair();
    final peerPub = (await peer.extractPublicKey()).bytes;
    final peerNonce = _fill(32, 6);
    final mls = _fill(32, 4);
    final hello = helloBytes(
      callId: _call,
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

    var helloPosted = false;
    var dtlsResolved = false;
    var resolveAfterHello = false;
    List<int>? localNonce;
    List<int>? localKey;
    var confirmPosted = false;

    final session = CallAuthSession(
      api: CallingApiClient(
        client: MockClient((request) async {
          if (request.url.path == '/calls/auth-key') {
            return http.Response('', 204);
          }
          if (request.method == 'POST' && request.url.path.endsWith('/auth')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (body['kind'] == 'hello') {
              helloPosted = true;
              localNonce = base64Decode(body['nonce_b64'] as String);
              localKey = base64Decode(body['call_public_key_b64'] as String);
            }
            if (body['kind'] == 'confirm') confirmPosted = true;
            return http.Response('{}', 200);
          }
          final frames = <Map<String, dynamic>>[
            {
              'kind': 'hello',
              'sender_user_id': _bob,
              'sender_device_id': _bobDev,
              'nonce_b64': base64Encode(peerNonce),
              'call_public_key_b64': base64Encode(peerPub),
              'mls_fingerprint_hex': _hex(mls),
              'signature_b64': base64Encode(helloSig),
            },
          ];
          if (confirmPosted && localNonce != null && localKey != null) {
            final transcript = CallTranscript(
              callId: _call,
              callerUser: _alice,
              calleeUser: _bob,
              callerDevice: _aliceDev,
              calleeDevice: _bobDev,
              mediaAudio: false,
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
      store: MemoryCallAuthStore(),
      deviceStillEnrolled: (peerUser, peerDevice) async => true,
      bindingExchange: ({
        required peerUserId,
        required peerDeviceId,
        required localStatement,
        required localSignature,
      }) async {
        return PeerBinding(statement: statement, signature: bindingSig);
      },
    );

    final outcome = await session.run(CallAuthRequest(
      session: CallSession.fromJson({
        'id': _call,
        'caller_user_id': _alice,
        'callee_user_id': _bob,
        'caller_device_id': _aliceDev,
        'callee_device_id': _bobDev,
        'media_type': 'video',
        'state': 'accepted',
        'client_call_id': 'c1',
        'ring_expires_at': DateTime.now().toUtc().add(const Duration(minutes: 1)).toIso8601String(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'version': 1,
      }),
      myUserId: _alice,
      resolveDtls: () async {
        resolveAfterHello = helloPosted;
        // Simulate slow video DTLS description reads.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        dtlsResolved = true;
        return (local: _fill(32, 1), remote: _fill(32, 2));
      },
    ));

    expect(helloPosted, isTrue);
    expect(resolveAfterHello, isTrue);
    expect(dtlsResolved, isTrue);
    expect(outcome.phase, CallAuthPhase.authenticated);
  });
}
