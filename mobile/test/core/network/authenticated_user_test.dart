import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:private_messenger/core/network/api_client.dart';

void main() {
  test('getAuthenticatedUser returns identity for valid token', () async {
    final mock = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/auth/me');
      expect(request.headers['Authorization'], 'Bearer test-session-token');

      return http.Response(
        jsonEncode({
          'user_id': '11111111-1111-4111-8111-111111111111',
          'device_id': '22222222-2222-4222-8222-222222222222',
          'expires_at': '2026-12-01T12:00:00Z',
        }),
        200,
      );
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    final identity = await api.getAuthenticatedUser('test-session-token');

    expect(identity.userId, isNotEmpty);
    expect(identity.deviceId, isNotEmpty);
  });

  test('getAuthenticatedUser rejects revoked sessions', () async {
    final mock = MockClient((request) async {
      return http.Response('authentication required', 401);
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    await expectLater(
      api.getAuthenticatedUser('revoked-token'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.kind,
          'kind',
          ApiErrorKind.unauthorized,
        ),
      ),
    );
  });

  test('getAuthenticatedUser rejects malformed responses', () async {
    final mock = MockClient((request) async {
      return http.Response(jsonEncode({'user_id': '123'}), 200);
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    await expectLater(
      api.getAuthenticatedUser('test-token'),
      throwsA(isA<ApiException>()),
    );
  });

  test('getAuthenticatedUser rejects empty tokens locally', () async {
    final mock = MockClient((request) async {
      fail('The server should not be contacted');
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    await expectLater(
      api.getAuthenticatedUser(''),
      throwsA(isA<ApiException>()),
    );
  });
}
