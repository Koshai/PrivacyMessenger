import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/core/network/api_client.dart';

import 'dart:convert';

void main() {
  group('ApiClient', () {
    test('health check succeeds', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/health');

        return http.Response('{"status":"ok"}', 200);
      });

      final api = ApiClient(
        client: client,
        baseUri: Uri.parse('http://localhost:4000'),
      );

      expect(await api.checkHealth(), isTrue);
      client.close();
    });

    test('health check rejects server errors', () async {
      final client = MockClient((_) async => http.Response('Unavailable', 503));

      final api = ApiClient(
        client: client,
        baseUri: Uri.parse('http://localhost:4000'),
      );

      await expectLater(api.checkHealth(), throwsA(isA<ApiException>()));

      client.close();
    });

    test('health check rejects invalid JSON', () async {
      final client = MockClient((_) async => http.Response('not json', 200));

      final api = ApiClient(
        client: client,
        baseUri: Uri.parse('http://localhost:4000'),
      );

      await expectLater(api.checkHealth(), throwsA(isA<ApiException>()));

      client.close();
    });

    test('OTP request returns a typed challenge', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/auth/request-otp');

        expect(jsonDecode(request.body), {'email': 'test@example.com'});

        return http.Response(
          jsonEncode({
            'message': 'Verification code requested',
            'challenge_id': '550e8400-e29b-41d4-a716-446655440000',
            'expires_at': '2030-01-01T12:00:00Z',
          }),
          202,
        );
      });

      final api = ApiClient(
        client: client,
        baseUri: Uri.parse('http://localhost:4000'),
      );

      final result = await api.requestOtp(' test@example.com ');

      expect(result.challengeId, '550e8400-e29b-41d4-a716-446655440000');

      expect(result.expiresAt.isUtc, isTrue);
      expect(result.message, 'Verification code requested');

      client.close();
    });

    test('OTP request rejects invalid email', () async {
      final client = MockClient(
        (_) async => http.Response('invalid email', 400),
      );

      final api = ApiClient(
        client: client,
        baseUri: Uri.parse('http://localhost:4000'),
      );

      await expectLater(
        api.requestOtp('invalid'),
        throwsA(isA<ApiException>()),
      );

      client.close();
    });

    test('OTP request handles rate limiting', () async {
      final client = MockClient(
        (_) async => http.Response('too many requests', 429),
      );

      final api = ApiClient(
        client: client,
        baseUri: Uri.parse('http://localhost:4000'),
      );

      await expectLater(
        api.requestOtp('test@example.com'),
        throwsA(isA<ApiException>()),
      );

      client.close();
    });
  });

  test('OTP request rejects missing challenge ID', () async {
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode({
          'message': 'Verification code requested',
          'expires_at': '2030-01-01T12:00:00Z',
        }),
        202,
      );
    });

    final api = ApiClient(
      client: client,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    await expectLater(
      api.requestOtp('test@example.com'),
      throwsA(isA<ApiException>()),
    );

    client.close();
  });

  test('OTP request rejects invalid expiration', () async {
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode({
          'message': 'Verification code requested',
          'challenge_id': '550e8400-e29b-41d4-a716-446655440000',
          'expires_at': 'not-a-date',
        }),
        202,
      );
    });

    final api = ApiClient(
      client: client,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    await expectLater(
      api.requestOtp('test@example.com'),
      throwsA(isA<ApiException>()),
    );

    client.close();
  });
}
