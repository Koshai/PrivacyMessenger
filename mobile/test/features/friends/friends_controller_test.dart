import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:private_messenger/core/auth/auth_controller.dart';
import 'package:private_messenger/core/auth/session_store.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/auth/models/auth_identity.dart';
import 'package:private_messenger/features/auth/models/auth_session.dart';
import 'package:private_messenger/features/friends/friends_controller.dart';

class FakeSessionStore implements SessionStore {
  AuthSession? session;

  @override
  Future<void> save(AuthSession value) async => session = value;

  @override
  Future<AuthSession?> read() async => session;

  @override
  Future<void> clear() async => session = null;
}

void main() {
  test('refresh loads friends and requests', () async {
    final mock = MockClient((request) async {
      switch (request.url.path) {
        case '/friends':
          return http.Response(
            '{"friends":[{"user_id":"u1","email":"a@example.com","since":"2026-01-01T00:00:00Z"}]}',
            200,
          );
        case '/friends/count':
          return http.Response('{"count":1}', 200);
        case '/friends/requests/incoming':
          return http.Response(
            '{"requests":[{"id":"r1","user_id":"u2","email":"b@example.com","created_at":"2026-01-01T00:00:00Z","outgoing":false}]}',
            200,
          );
        case '/friends/requests/outgoing':
          return http.Response('{"requests":[]}', 200);
        case '/friends/blocks':
          return http.Response('{"blocked":[]}', 200);
        default:
          return http.Response('missing', 404);
      }
    });

    final store = FakeSessionStore()
      ..session = AuthSession(
        userId: 'me',
        deviceId: 'device',
        token: 'token',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

    final auth = AuthController(
      store: store,
      validate: (_) async => AuthIdentity(
        userId: 'me',
        deviceId: 'device',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
      revoke: (_) async {},
    );
    addTearDown(auth.dispose);

    final controller = FriendsController(
      apiClient: ApiClient(
        client: mock,
        baseUri: Uri.parse('http://localhost:4000'),
      ),
      authController: auth,
    );

    await controller.refresh();

    expect(controller.loadState, FriendsLoadState.ready);
    expect(controller.friends, hasLength(1));
    expect(controller.friendCount, 1);
    expect(controller.incoming, hasLength(1));
  });

  test('sendRequest then refresh', () async {
    var sent = false;
    final mock = MockClient((request) async {
      if (request.url.path == '/friends/requests' &&
          request.method == 'POST') {
        sent = true;
        return http.Response('{"message":"ok"}', 202);
      }
      if (request.url.path == '/friends') {
        return http.Response('{"friends":[]}', 200);
      }
      if (request.url.path == '/friends/count') {
        return http.Response('{"count":0}', 200);
      }
      if (request.url.path.contains('/requests/')) {
        return http.Response('{"requests":[]}', 200);
      }
      if (request.url.path == '/friends/blocks') {
        return http.Response('{"blocked":[]}', 200);
      }
      return http.Response('missing', 404);
    });

    final store = FakeSessionStore()
      ..session = AuthSession(
        userId: 'me',
        deviceId: 'device',
        token: 'token',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

    final auth = AuthController(
      store: store,
      validate: (_) async => AuthIdentity(
        userId: 'me',
        deviceId: 'device',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
      revoke: (_) async {},
    );
    addTearDown(auth.dispose);

    final controller = FriendsController(
      apiClient: ApiClient(
        client: mock,
        baseUri: Uri.parse('http://localhost:4000'),
      ),
      authController: auth,
    );

    await controller.sendRequest('friend@example.com');
    expect(sent, isTrue);
    expect(controller.loadState, FriendsLoadState.ready);
  });
}
