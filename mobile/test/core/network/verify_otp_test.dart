import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:private_messenger/core/network/api_client.dart';

void main() {
  const challengeId = '550e8400-e29b-41d4-a716-446655440000';

  test('verifyOtp returns a session for a valid code', () async {
    final mock = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/auth/verify-otp');

      final body = jsonDecode(request.body) as Map<String, dynamic>;

      expect(body['challenge_id'], challengeId);
      expect(body['code'], '123456');
      expect(body['device_name'], 'Android Emulator');

      return http.Response(
        jsonEncode({
          'user_id': '11111111-1111-4111-8111-111111111111',
          'device_id': '22222222-2222-4222-8222-222222222222',
          'token': 'test-session-token',
          'expires_at': '2026-12-01T12:00:00Z',
        }),
        200,
      );
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    final session = await api.verifyOtp(
      challengeId: challengeId,
      code: '123456',
      deviceName: 'Android Emulator',
    );

    expect(session.token, 'test-session-token');
    expect(session.userId, isNotEmpty);
    expect(session.deviceId, isNotEmpty);
  });

  test('verifyOtp rejects an invalid code locally', () async {
    final mock = MockClient((request) async {
      fail('The server should not be contacted');
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    await expectLater(
      api.verifyOtp(
        challengeId: challengeId,
        code: '123',
        deviceName: 'Android Emulator',
      ),
      throwsA(isA<ApiException>()),
    );
  });

  test('verifyOtp handles rejected codes', () async {
    final mock = MockClient((request) async {
      return http.Response('invalid or expired verification code', 401);
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    await expectLater(
      api.verifyOtp(
        challengeId: challengeId,
        code: '000000',
        deviceName: 'Android Emulator',
      ),
      throwsA(isA<ApiException>()),
    );
  });

  test('verifyOtp rejects malformed session responses', () async {
    final mock = MockClient((request) async {
      return http.Response(jsonEncode({'user_id': '123'}), 200);
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    await expectLater(
      api.verifyOtp(
        challengeId: challengeId,
        code: '123456',
        deviceName: 'Android Emulator',
      ),
      throwsA(isA<ApiException>()),
    );
  });
}
