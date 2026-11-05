import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';

/// Two logical clients exchanging offer/answer through a mocked Go signaling API.
void main() {
  test('two clients complete offer/answer via signaling API', () async {
    final store = <String, Map<String, dynamic>>{};
    final ice = <Map<String, dynamic>>[];

    http.Response handle(http.Request req) {
      final path = req.url.path;
      if (req.method == 'POST' && path == '/calls') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final id = 'call-shared';
        store[id] = {
          'id': id,
          'caller_user_id': 'alice',
          'callee_user_id': 'bob',
          'caller_device_id': 'adev',
          'media_type': body['media_type'],
          'state': 'ringing',
          'client_call_id': body['client_call_id'],
          'ring_expires_at': DateTime.now().toUtc().add(const Duration(minutes: 1)).toIso8601String(),
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'version': 0,
        };
        return http.Response(jsonEncode(store[id]), 201);
      }
      if (path.endsWith('/accept')) {
        store['call-shared']!['state'] = 'accepted';
        store['call-shared']!['callee_device_id'] = 'bdev';
        return http.Response(jsonEncode(store['call-shared']), 200);
      }
      if (path.endsWith('/offer') && req.method == 'PUT') {
        final sdp = (jsonDecode(req.body) as Map)['sdp'];
        store['call-shared']!['sdp_offer'] = sdp;
        return http.Response(jsonEncode(store['call-shared']), 200);
      }
      if (path.endsWith('/answer') && req.method == 'PUT') {
        final sdp = (jsonDecode(req.body) as Map)['sdp'];
        store['call-shared']!['sdp_answer'] = sdp;
        store['call-shared']!['state'] = 'accepted';
        return http.Response(jsonEncode(store['call-shared']), 200);
      }
      if (path.endsWith('/connected')) {
        store['call-shared']!['state'] = 'connected';
        return http.Response(jsonEncode(store['call-shared']), 200);
      }
      if (path.endsWith('/ice') && req.method == 'POST') {
        ice.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response('{}', 201);
      }
      if (path.endsWith('/ice') && req.method == 'GET') {
        return http.Response(jsonEncode({'candidates': []}), 200);
      }
      if (path.endsWith('/hangup')) {
        store['call-shared']!['state'] = 'ended';
        store['call-shared']!['end_reason'] = 'hangup';
        return http.Response(jsonEncode(store['call-shared']), 200);
      }
      if (req.method == 'GET' && path.startsWith('/calls/')) {
        return http.Response(jsonEncode(store['call-shared']), 200);
      }
      return http.Response('missing ${req.method} $path', 404);
    }

    final aliceMedia = FakeCallService();
    final bobMedia = FakeCallService();
    final alice = CallController(
      api: CallingApiClient(client: MockClient((r) async => handle(r)), baseUri: Uri.parse('http://sig')),
      media: aliceMedia,
      myUserId: 'alice',
      tokenProvider: () => 'a',
      requestPermissions: (_) async => true,
      authenticatePeer: (_) async =>
          const CallAuthOutcome(phase: CallAuthPhase.authenticated),
    );
    final bob = CallController(
      api: CallingApiClient(client: MockClient((r) async => handle(r)), baseUri: Uri.parse('http://sig')),
      media: bobMedia,
      myUserId: 'bob',
      tokenProvider: () => 'b',
      requestPermissions: (_) async => true,
      authenticatePeer: (_) async =>
          const CallAuthOutcome(phase: CallAuthPhase.authenticated),
    );

    await alice.startOutgoing(peerUserId: 'bob', mediaType: CallMediaType.audio);
    expect(store['call-shared']?['sdp_offer'], isNotNull);

    bob.session = CallSession.fromJson(store['call-shared']!);
    bob.phase = CallPhase.incomingRinging;
    await bob.acceptIncoming();

    expect(bobMedia.remoteOffer, isNotNull);
    expect(store['call-shared']?['sdp_answer'], isNotNull);

    await alice.media.applyRemoteAnswer(store['call-shared']!['sdp_answer'] as String);
    aliceMedia.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(store['call-shared']?['state'], anyOf('accepted', 'connected'));
    await alice.hangUp();
    await bob.hangUp();
  });
}
