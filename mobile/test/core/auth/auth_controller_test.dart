import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:private_messenger/core/auth/auth_controller.dart';
import 'package:private_messenger/core/auth/auth_state.dart';
import 'package:private_messenger/core/auth/session_store.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/auth/models/auth_identity.dart';
import 'package:private_messenger/features/auth/models/auth_session.dart';

class FakeSessionStore implements SessionStore {
  AuthSession? session;
  int clearCount = 0;
  int saveCount = 0;
  Completer<void>? blockRead;

  @override
  Future<void> save(AuthSession value) async {
    saveCount++;
    session = value;
  }

  @override
  Future<AuthSession?> read() async {
    final blocker = blockRead;
    if (blocker != null) {
      await blocker.future;
    }
    return session;
  }

  @override
  Future<void> clear() async {
    clearCount++;
    session = null;
  }
}

void main() {
  late FakeSessionStore store;

  AuthSession createSession({String token = 'test-token'}) => AuthSession(
    userId: 'user-1',
    deviceId: 'device-1',
    token: token,
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );

  AuthIdentity createIdentity() => AuthIdentity(
    userId: 'user-1',
    deviceId: 'device-1',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
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

  test('revoked session is cleared using typed unauthorized error', () async {
    store.session = createSession();

    final controller = AuthController(
      store: store,
      validate: (_) async {
        throw const ApiException(
          'Session expired or revoked',
          kind: ApiErrorKind.unauthorized,
          statusCode: 401,
        );
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
        throw const ApiException(
          'Unable to connect to authentication server',
          kind: ApiErrorKind.network,
        );
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

  test('successful logout revokes then clears local session', () async {
    store.session = createSession();
    var revokedToken = '';

    final controller = AuthController(
      store: store,
      validate: (_) async => createIdentity(),
      revoke: (token) async {
        revokedToken = token;
      },
    );
    addTearDown(controller.dispose);

    await controller.restore();
    expect(controller.state.status, AuthStatus.authenticated);

    await controller.signOut();

    expect(revokedToken, 'test-token');
    expect(store.session, isNull);
    expect(controller.state.status, AuthStatus.signedOut);
  });

  test('logout network failure keeps local session', () async {
    store.session = createSession();

    final controller = AuthController(
      store: store,
      validate: (_) async => createIdentity(),
      revoke: (_) async {
        throw const ApiException(
          'Unable to contact the server. Please try logging out again.',
          kind: ApiErrorKind.network,
        );
      },
    );
    addTearDown(controller.dispose);

    await controller.restore();

    await expectLater(controller.signOut(), throwsA(isA<ApiException>()));

    expect(store.session, isNotNull);
    expect(controller.state.status, AuthStatus.authenticated);
  });

  test('duplicate logout submissions only revoke once', () async {
    store.session = createSession();
    var revokeCalls = 0;
    final allowRevoke = Completer<void>();

    final controller = AuthController(
      store: store,
      validate: (_) async => createIdentity(),
      revoke: (_) async {
        revokeCalls++;
        await allowRevoke.future;
      },
    );
    addTearDown(controller.dispose);

    await controller.restore();

    final first = controller.signOut();
    final second = controller.signOut();

    allowRevoke.complete();
    await Future.wait([first, second]);

    expect(revokeCalls, 1);
    expect(controller.state.status, AuthStatus.signedOut);
    expect(store.session, isNull);
  });

  test('stale validation completion does not overwrite newer state', () async {
    store.session = createSession(token: 'old-token');

    final slowValidate = Completer<AuthIdentity>();

    final controller = AuthController(
      store: store,
      validate: (token) async {
        if (token == 'old-token') {
          return slowValidate.future;
        }
        return createIdentity();
      },
      revoke: (_) async {},
    );
    addTearDown(controller.dispose);

    final restoreFuture = controller.restore();

    await controller.signIn(createSession(token: 'new-token'));
    expect(controller.state.status, AuthStatus.authenticated);

    slowValidate.complete(createIdentity());
    await restoreFuture;

    expect(controller.state.status, AuthStatus.authenticated);
    expect(store.session?.token, 'new-token');
  });

  test('identity mismatch clears invalid session', () async {
    store.session = createSession();

    final controller = AuthController(
      store: store,
      validate: (_) async => AuthIdentity(
        userId: 'other-user',
        deviceId: 'device-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
      revoke: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.restore();

    expect(controller.state.status, AuthStatus.signedOut);
    expect(store.session, isNull);
    expect(store.clearCount, greaterThan(0));
  });
}
