import 'package:flutter_test/flutter_test.dart';

import 'package:private_messenger/core/auth/auth_controller.dart';
import 'package:private_messenger/core/auth/auth_state.dart';
import 'package:private_messenger/core/auth/session_store.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/auth/models/auth_identity.dart';
import 'package:private_messenger/features/auth/models/auth_session.dart';

class FakeSessionStore implements SessionStore {
  AuthSession? session;

  @override
  Future<void> save(AuthSession value) async {
    session = value;
  }

  @override
  Future<AuthSession?> read() async => session;

  @override
  Future<void> clear() async {
    session = null;
  }
}

void main() {
  late FakeSessionStore store;

  AuthSession createSession() => AuthSession(
    userId: 'user-1',
    deviceId: 'device-1',
    token: 'test-token',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );

  AuthIdentity createIdentity() => AuthIdentity(
    userId: 'user-1',
    deviceId: 'device-1',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );

  setUp(() {
    store = FakeSessionStore();
  });

  test('no stored session results in signedOut', () async {
    final controller = AuthController(
      store: store,
      validate: (_) async => createIdentity(),
      revoke: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.restore();

    expect(controller.state.status, AuthStatus.signedOut);
  });

  test('valid stored session restores authentication', () async {
    store.session = createSession();

    final controller = AuthController(
      store: store,
      validate: (_) async => createIdentity(),
      revoke: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.restore();

    expect(controller.state.status, AuthStatus.authenticated);
    expect(controller.state.userId, 'user-1');
  });

  test('revoked session is cleared', () async {
    store.session = createSession();

    final controller = AuthController(
      store: store,
      validate: (_) async {
        throw ApiException('Session expired or revoked');
      },
      revoke: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.restore();

    expect(controller.state.status, AuthStatus.signedOut);
    expect(store.session, isNull);
  });

  test('network failure retains stored session', () async {
    store.session = createSession();

    final controller = AuthController(
      store: store,
      validate: (_) async {
        throw ApiException('Unable to connect to authentication server');
      },
      revoke: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.restore();

    expect(controller.state.status, AuthStatus.unavailable);
    expect(store.session, isNotNull);
  });

  test('signIn stores and validates session', () async {
    final controller = AuthController(
      store: store,
      validate: (_) async => createIdentity(),
      revoke: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.signIn(createSession());

    expect(store.session, isNotNull);
    expect(controller.state.status, AuthStatus.authenticated);
  });
}
