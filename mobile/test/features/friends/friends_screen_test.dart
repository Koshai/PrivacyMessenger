import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:private_messenger/core/auth/auth_controller.dart';
import 'package:private_messenger/core/auth/session_store.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/auth/models/auth_identity.dart';
import 'package:private_messenger/features/auth/models/auth_session.dart';
import 'package:private_messenger/features/friends/friends_screen.dart';

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
  testWidgets('renders empty friends state while loading completes', (
    tester,
  ) async {
    final mock = MockClient((request) async {
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

    await tester.pumpWidget(
      MaterialApp(
        home: FriendsScreen(
          apiClient: ApiClient(
            client: mock,
            baseUri: Uri.parse('http://localhost:4000'),
          ),
          authController: auth,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Your friends are private'), findsOneWidget);
    expect(find.text('No friends yet. Send a request above.'), findsOneWidget);
    expect(find.text('Send request'), findsOneWidget);
  });

  testWidgets('shows error state with retry', (tester) async {
    final mock = MockClient((_) async => http.Response('nope', 500));

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

    await tester.pumpWidget(
      MaterialApp(
        home: FriendsScreen(
          apiClient: ApiClient(
            client: mock,
            baseUri: Uri.parse('http://localhost:4000'),
          ),
          authController: auth,
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('accept and reject controls render for incoming requests', (
    tester,
  ) async {
    final mock = MockClient((request) async {
      if (request.url.path == '/friends') {
        return http.Response('{"friends":[]}', 200);
      }
      if (request.url.path == '/friends/count') {
        return http.Response('{"count":0}', 200);
      }
      if (request.url.path == '/friends/requests/incoming') {
        return http.Response(
          '{"requests":[{"id":"r1","user_id":"u2","email":"b@example.com","created_at":"2026-01-01T00:00:00Z","outgoing":false}]}',
          200,
        );
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

    await tester.pumpWidget(
      MaterialApp(
        home: FriendsScreen(
          apiClient: ApiClient(
            client: mock,
            baseUri: Uri.parse('http://localhost:4000'),
          ),
          authController: auth,
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('b@example.com'), findsOneWidget);
    expect(find.text('Accept invitation'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
  });

  testWidgets('removing a friend requires confirmation and cancel is safe', (
    tester,
  ) async {
    var removeCalls = 0;
    final mock = MockClient((request) async {
      if (request.method == 'DELETE' &&
          request.url.path.startsWith('/friends/') &&
          !request.url.path.contains('blocks')) {
        removeCalls++;
        return http.Response('', 204);
      }
      if (request.url.path == '/friends') {
        return http.Response(
          '{"friends":[{"user_id":"u2","email":"friend@example.com","since":"2026-01-01T00:00:00Z"}]}',
          200,
        );
      }
      if (request.url.path == '/friends/count') {
        return http.Response('{"count":1}', 200);
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

    await tester.pumpWidget(
      MaterialApp(
        home: FriendsScreen(
          apiClient: ApiClient(
            client: mock,
            baseUri: Uri.parse('http://localhost:4000'),
          ),
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Friend actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove friend').last);
    await tester.pumpAndSettle();
    expect(find.text('Remove friend?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(removeCalls, 0);
    expect(find.text('friend@example.com'), findsOneWidget);

    await tester.tap(find.byTooltip('Friend actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove friend').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(removeCalls, 1);
  });

  testWidgets('blocking a friend requires confirmation', (tester) async {
    var blockCalls = 0;
    final mock = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.contains('/blocks')) {
        blockCalls++;
        return http.Response('', 204);
      }
      if (request.url.path == '/friends') {
        return http.Response(
          '{"friends":[{"user_id":"u2","email":"friend@example.com","since":"2026-01-01T00:00:00Z"}]}',
          200,
        );
      }
      if (request.url.path == '/friends/count') {
        return http.Response('{"count":1}', 200);
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

    await tester.pumpWidget(
      MaterialApp(
        home: FriendsScreen(
          apiClient: ApiClient(
            client: mock,
            baseUri: Uri.parse('http://localhost:4000'),
          ),
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Friend actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block').last);
    await tester.pumpAndSettle();
    expect(find.text('Block user?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Block'));
    await tester.pumpAndSettle();
    expect(blockCalls, 1);
  });
}
