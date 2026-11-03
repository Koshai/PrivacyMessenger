import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/core/network/api_client.dart';

void main() {
  test('sendFriendRequest posts email', () async {
    final mock = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/friends/requests');
      expect(jsonDecode(request.body), {'email': 'friend@example.com'});
      return http.Response('{"message":"ok"}', 202);
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    await api.sendFriendRequest(
      token: 'token',
      email: 'friend@example.com',
    );
  });

  test('listFriends parses payload', () async {
    final mock = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'friends': [
            {
              'user_id': 'u1',
              'email': 'a@example.com',
              'since': '2026-01-01T00:00:00Z',
            },
          ],
        }),
        200,
      );
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    final friends = await api.listFriends('token');
    expect(friends, hasLength(1));
    expect(friends.first.email, 'a@example.com');
  });

  test('acceptFriendRequest hits accept route', () async {
    final mock = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/friends/requests/req-1/accept');
      return http.Response('', 204);
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    await api.acceptFriendRequest(token: 'token', requestId: 'req-1');
  });

  test('blockUser posts user id', () async {
    final mock = MockClient((request) async {
      expect(request.url.path, '/friends/blocks');
      expect(jsonDecode(request.body), {'user_id': 'u2'});
      return http.Response('', 204);
    });

    final api = ApiClient(
      client: mock,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    await api.blockUser(token: 'token', userId: 'u2');
  });
}
