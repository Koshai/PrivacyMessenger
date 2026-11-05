import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/ice_servers.dart';

void main() {
  test('parses stun and turn urls with temporary credentials', () {
    final config = IceServerConfig.fromJson({
      'ttl_seconds': 600,
      'expires_at': '2099-01-01T00:00:00Z',
      'ice_servers': [
        {'urls': 'stun:turn.example.test:3478'},
        {
          'urls': [
            'turn:turn.example.test:3478?transport=udp',
            'turn:turn.example.test:3478?transport=tcp',
            'turns:turn.example.test:5349?transport=tcp',
          ],
          'username': '123:user',
          'credential': 'temp-pass',
        },
      ],
    });
    expect(config.hasTurn, isTrue);
    expect(config.isExpired, isFalse);
    expect(config.servers[1].credential, 'temp-pass');
    final mapped = config.toFlutterWebRtcIceServers();
    expect(mapped.first['urls'], 'stun:turn.example.test:3478');
    expect(mapped.last['credential'], 'temp-pass');
  });

  test('expired credentials are detected', () {
    final config = IceServerConfig.fromJson({
      'expires_at': '2000-01-01T00:00:00Z',
      'ice_servers': [
        {'urls': ['turn:turn.example.test:3478']},
      ],
    });
    expect(config.isExpired, isTrue);
  });

  test('relay-only copy requires turn urls', () {
    final direct = IceServerConfig.fromJson({
      'expires_at': '2099-01-01T00:00:00Z',
      'ice_servers': [
        {'urls': 'stun:stun.example.test:3478'},
      ],
    });
    final relay = direct.copyWith(relayOnly: true);
    expect(relay.relayOnly, isTrue);
    expect(relay.hasTurn, isFalse);
  });

  test('TURN unavailable maps to ApiException', () async {
    final api = CallingApiClient(
      client: MockClient((_) async => http.Response('TURN unavailable', 503)),
      baseUri: Uri.parse('http://example.test'),
    );
    await expectLater(
      api.iceConfig(token: 't'),
      throwsA(
        isA<ApiException>().having((e) => e.message, 'message', contains('TURN unavailable')),
      ),
    );
  });

  test('ice config response does not include a shared secret field', () async {
    const secret = 'test-turn-secret-value';
    final api = CallingApiClient(
      client: MockClient((_) async {
        return http.Response(
          jsonEncode({
            'ttl_seconds': 600,
            'expires_at': '2099-01-01T00:00:00Z',
            'ice_servers': [
              {
                'urls': ['turn:turn.example.test:3478?transport=udp'],
                'username': '1:user',
                'credential': 'not-the-secret',
              },
            ],
          }),
          200,
        );
      }),
      baseUri: Uri.parse('http://example.test'),
    );
    final config = await api.iceConfig(token: 't', relayOnly: true);
    final encoded = jsonEncode(config.toFlutterWebRtcIceServers());
    expect(encoded.contains(secret), isFalse);
    expect(config.relayOnly, isTrue);
    expect(config.hasTurn, isTrue);
  });
}
