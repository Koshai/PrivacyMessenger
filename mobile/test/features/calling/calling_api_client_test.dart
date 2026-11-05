import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';

void main() {
  test('maps privacy 404 to ApiException', () async {
    final client = MockClient((_) async => http.Response('call not available', 404));
    final api = CallingApiClient(client: client, baseUri: Uri.parse('http://x'));
    await expectLater(
      api.initiate(
        token: 't',
        calleeUserId: 'b',
        mediaType: CallMediaType.audio,
        clientCallId: 'c',
      ),
      throwsA(isA<ApiException>()),
    );
  });

  test('parses initiate response', () async {
    final body = {
      'id': '1',
      'caller_user_id': 'a',
      'callee_user_id': 'b',
      'caller_device_id': 'd',
      'media_type': 'video',
      'state': 'ringing',
      'client_call_id': 'c',
      'ring_expires_at': '2026-01-01T00:00:00Z',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
      'version': 0,
    };
    final client = MockClient((_) async => http.Response(jsonEncode(body), 201));
    final api = CallingApiClient(client: client, baseUri: Uri.parse('http://x'));
    final session = await api.initiate(
      token: 't',
      calleeUserId: 'b',
      mediaType: CallMediaType.video,
      clientCallId: 'c',
    );
    expect(session.mediaType, CallMediaType.video);
    expect(session.state, CallRemoteState.ringing);
  });
}
