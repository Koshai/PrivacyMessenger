import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../features/auth/models/auth_identity.dart';
import '../../features/auth/models/auth_session.dart';
import '../network/api_client.dart';
import 'auth_state.dart';
import 'session_store.dart';

typedef SessionValidator = Future<AuthIdentity> Function(String token);
typedef SessionRevoker = Future<void> Function(String token);

class AuthController extends ChangeNotifier {
  final SessionStore _store;
  final SessionValidator _validate;
  final SessionRevoker _revoke;

  AuthState _state = const AuthState(status: AuthStatus.initial);

  int _generation = 0;
  bool _disposed = false;
  bool _signingOut = false;
  Future<void> _storeGate = Future<void>.value();

  AuthController({
    required SessionStore store,
    required SessionValidator validate,
    required SessionRevoker revoke,
    // ignore: prefer_initializing_formals
  }) : _store = store,
       // ignore: prefer_initializing_formals
       _validate = validate,
       // ignore: prefer_initializing_formals
       _revoke = revoke;

  AuthState get state => _state;

  bool get isSigningOut => _signingOut;

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<String?> sessionToken() async {
    final session = await _withStore(_store.read);
    return session?.token;
  }

  void _update(AuthState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  Future<T> _withStore<T>(Future<T> Function() action) {
    final previous = _storeGate;
    final gate = Completer<void>();
    _storeGate = gate.future;

    return previous.then((_) => action()).whenComplete(() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    });
  }

  /// Clears local storage only when this generation is still current and the
  /// stored token still matches [expectedToken]. Prevents a stale validation
  /// from wiping a newer sign-in or an in-flight sign-out from racing.
  Future<void> _clearIfCurrent(int generation, String expectedToken) {
    return _withStore(() async {
      if (!_isCurrent(generation)) return;
      final current = await _store.read();
      if (!_isCurrent(generation)) return;
      if (current?.token == expectedToken) {
        await _store.clear();
      }
    });
  }

  Future<void> restore() async {
    final generation = ++_generation;

    _update(const AuthState(status: AuthStatus.checking));

    try {
      final session = await _withStore(_store.read);

      if (!_isCurrent(generation)) return;

      if (session == null) {
        _update(const AuthState(status: AuthStatus.signedOut));
        return;
      }

      await _validateSession(session, generation);
    } catch (_) {
      if (!_isCurrent(generation)) return;

      _update(
        const AuthState(
          status: AuthStatus.unavailable,
          message: 'Unable to restore session',
        ),
      );
    }
  }

  Future<void> signIn(AuthSession session) async {
    final generation = ++_generation;

    _update(const AuthState(status: AuthStatus.checking));

    try {
      await _withStore(() async {
        if (!_isCurrent(generation)) return;
        await _store.save(session);
      });

      if (!_isCurrent(generation)) return;

      await _validateSession(session, generation);
    } catch (_) {
      if (!_isCurrent(generation)) return;

      _update(
        const AuthState(
          status: AuthStatus.unavailable,
          message: 'Unable to save or validate session',
        ),
      );
    }
  }

  Future<void> _validateSession(AuthSession session, int generation) async {
    try {
      final identity = await _validate(session.token);

      if (!_isCurrent(generation)) return;

      if (identity.userId != session.userId ||
          identity.deviceId != session.deviceId ||
          !DateTime.now().toUtc().isBefore(identity.expiresAt)) {
        await _clearIfCurrent(generation, session.token);

        if (!_isCurrent(generation)) return;

        _update(const AuthState(status: AuthStatus.signedOut));
        return;
      }

      _update(
        AuthState(status: AuthStatus.authenticated, userId: identity.userId),
      );
    } on ApiException catch (e) {
      if (!_isCurrent(generation)) return;

      if (e.isUnauthorized) {
        await _clearIfCurrent(generation, session.token);

        if (!_isCurrent(generation)) return;

        _update(const AuthState(status: AuthStatus.signedOut));
      } else {
        _update(
          const AuthState(
            status: AuthStatus.unavailable,
            message: 'Cannot validate session. Try again.',
          ),
        );
      }
    }
  }

  Future<void> clearLocalSession() async {
    ++_generation;
    await _withStore(_store.clear);
    _update(const AuthState(status: AuthStatus.signedOut));
  }

  /// Revokes the server session then clears local storage.
  ///
  /// Concurrent calls are ignored while a logout is in flight.
  /// Network failures propagate and leave the local session intact.
  Future<void> signOut() async {
    if (_signingOut || _disposed) return;

    _signingOut = true;
    final generation = ++_generation;

    try {
      final session = await _withStore(_store.read);

      if (!_isCurrent(generation)) return;

      if (session == null) {
        await _withStore(() async {
          if (!_isCurrent(generation)) return;
          await _store.clear();
        });
        if (!_isCurrent(generation)) return;
        _update(const AuthState(status: AuthStatus.signedOut));
        return;
      }

      await _revoke(session.token);

      if (!_isCurrent(generation)) return;

      await _clearIfCurrent(generation, session.token);

      if (!_isCurrent(generation)) return;

      _update(const AuthState(status: AuthStatus.signedOut));
    } finally {
      _signingOut = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
