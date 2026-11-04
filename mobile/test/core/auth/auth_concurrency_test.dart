import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:private_messenger/core/auth/auth_controller.dart';
import 'package:private_messenger/core/auth/auth_state.dart';
import 'package:private_messenger/core/auth/session_store.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/auth/models/auth_identity.dart';
import 'package:private_messenger/features/auth/models/auth_session.dart';

class DelayedSessionStore implements SessionStore {
  AuthSession? session;
  Completer<void>? blockNextRead;
  Completer<void>? blockNextSave;
  Completer<void>? blockNextClear;
  int clearCount = 0;

  @override
  Future<void> save(AuthSession value) async {
    final blocker = blockNextSave;
    blockNextSave = null;
    if (blocker != null) {
      await blocker.future;
    }
    session = value;
  }

  @override
  Future<AuthSession?> read() async {
    final blocker = blockNextRead;
    blockNextRead = null;
    if (blocker != null) {
      await blocker.future;
    }
    return session;
  }

  @override
  Future<void> clear() async {
    final blocker = blockNextClear;
    blockNextClear = null;
    if (blocker != null) {
      await blocker.future;
    }
    clearCount++;
    session = null;
  }
}

void main() {
  AuthSession session({String token = 'token-a'}) => AuthSession(
    userId: 'user-1',
    deviceId: 'device-1',
    token: token,
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );

  AuthIdentity identity() => AuthIdentity(
    userId: 'user-1',
    deviceId: 'device-1',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );

  test('stale unauthorized restore must not clear a newer signed-in session', () async {
    final store = DelayedSessionStore()..session = session(token: 'old-token');
    final slowUnauthorized = Completer<AuthIdentity>();

    final controller = AuthController(
      store: store,
      validate: (token) async {
        if (token == 'old-token') {
          await slowUnauthorized.future;
          throw const ApiException(
            'Session expired or revoked',
            kind: ApiErrorKind.unauthorized,
            statusCode: 401,
          );
        }
        return identity();
      },
      revoke: (_) async {},
    );
    addTearDown(controller.dispose);

    final restoreFuture = controller.restore();
    await Future<void>.delayed(Duration.zero);

    await controller.signIn(session(token: 'new-token'));
    expect(controller.state.status, AuthStatus.authenticated);
    expect(store.session?.token, 'new-token');

    slowUnauthorized.complete(identity());
    await restoreFuture;

    expect(controller.state.status, AuthStatus.authenticated);
    expect(store.session?.token, 'new-token');
  });

  test('signOut overlapping delayed restore does not restore cleared session', () async {
    final store = DelayedSessionStore()..session = session(token: 'live-token');
    final allowValidate = Completer<void>();
    final allowRevoke = Completer<void>();

    final controller = AuthController(
      store: store,
      validate: (_) async {
        await allowValidate.future;
        return identity();
      },
      revoke: (_) async {
        await allowRevoke.future;
      },
    );
    addTearDown(controller.dispose);

    final restoreFuture = controller.restore();
    await Future<void>.delayed(Duration.zero);

    final signOutFuture = controller.signOut();
    await Future<void>.delayed(Duration.zero);

    allowRevoke.complete();
    await signOutFuture;

    expect(controller.state.status, AuthStatus.signedOut);
    expect(store.session, isNull);

    allowValidate.complete();
    await restoreFuture;

    expect(controller.state.status, AuthStatus.signedOut);
    expect(store.session, isNull);
  });

  test('delayed signIn save discarded when signOut wins generation', () async {
    final store = DelayedSessionStore();
    final allowSave = Completer<void>();
    store.blockNextSave = allowSave;

    final controller = AuthController(
      store: store,
      validate: (_) async => identity(),
      revoke: (_) async {},
    );
    addTearDown(controller.dispose);

    final signInFuture = controller.signIn(session(token: 'late-token'));
    await Future<void>.delayed(Duration.zero);

    // No session yet — signOut should complete as local signed-out.
    final signOutFuture = controller.signOut();
    await Future<void>.delayed(Duration.zero);

    allowSave.complete();
    await Future.wait([signInFuture, signOutFuture]);

    expect(controller.state.status, AuthStatus.signedOut);
    expect(store.session, isNull);
  });

  test('stale identity-mismatch clear must not wipe newer session', () async {
    final store = DelayedSessionStore()..session = session(token: 'old-token');
    final slowMismatch = Completer<AuthIdentity>();

    final controller = AuthController(
      store: store,
      validate: (token) async {
        if (token == 'old-token') {
          return slowMismatch.future;
        }
        return identity();
      },
      revoke: (_) async {},
    );
    addTearDown(controller.dispose);

    final restoreFuture = controller.restore();
    await Future<void>.delayed(Duration.zero);

    await controller.signIn(session(token: 'new-token'));
    expect(store.session?.token, 'new-token');

    slowMismatch.complete(
      AuthIdentity(
        userId: 'other-user',
        deviceId: 'device-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
    );
    await restoreFuture;

    expect(controller.state.status, AuthStatus.authenticated);
    expect(store.session?.token, 'new-token');
  });

  test('signIn overlapping delayed signOut clear keeps newer session when tokens differ', () async {
    final store = DelayedSessionStore()..session = session(token: 'old-token');
    final allowRevoke = Completer<void>();
    final allowClear = Completer<void>();

    final controller = AuthController(
      store: store,
      validate: (_) async => identity(),
      revoke: (_) async {
        await allowRevoke.future;
      },
    );
    addTearDown(controller.dispose);

    await controller.restore();
    expect(controller.state.status, AuthStatus.authenticated);

    store.blockNextClear = allowClear;
    final signOutFuture = controller.signOut();
    await Future<void>.delayed(Duration.zero);

    allowRevoke.complete();
    await Future<void>.delayed(Duration.zero);

    // Sign-in while sign-out is waiting to clear.
    final signInFuture = controller.signIn(session(token: 'new-token'));
    await Future<void>.delayed(Duration.zero);

    allowClear.complete();
    await Future.wait([signOutFuture, signInFuture]);

    expect(controller.state.status, AuthStatus.authenticated);
    expect(store.session?.token, 'new-token');
  });
}
