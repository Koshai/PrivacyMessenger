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

  // ignore: prefer_initializing_formals

  AuthController({
    required SessionStore store,
    required SessionValidator validate,
    required SessionRevoker revoke,
  }) : _store = store,
       _validate = validate,
       _revoke = revoke;

  AuthState get state => _state;

  void _update(AuthState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  Future<void> restore() async {
    final generation = ++_generation;

    _update(const AuthState(status: AuthStatus.checking));

    try {
      final session = await _store.read();

      if (_disposed || generation != _generation) return;

      if (session == null) {
        _update(const AuthState(status: AuthStatus.signedOut));
        return;
      }

      await _validateSession(session, generation);
    } catch (_) {
      if (_disposed || generation != _generation) return;

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
      await _store.save(session);

      if (_disposed || generation != _generation) return;

      await _validateSession(session, generation);
    } catch (_) {
      if (_disposed || generation != _generation) return;

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

      if (_disposed || generation != _generation) return;

      if (identity.userId != session.userId ||
          identity.deviceId != session.deviceId ||
          !DateTime.now().toUtc().isBefore(identity.expiresAt)) {
        await _store.clear();

        if (_disposed || generation != _generation) return;

        _update(const AuthState(status: AuthStatus.signedOut));
        return;
      }

      _update(
        AuthState(status: AuthStatus.authenticated, userId: identity.userId),
      );
    } on ApiException catch (e) {
      if (_disposed || generation != _generation) return;

      // This matches the current ApiClient's 401 response.
      // A typed API error will be preferable in a later refactor.
      if (e.message == 'Session expired or revoked') {
        await _store.clear();

        if (_disposed || generation != _generation) return;

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
    await _store.clear();
    _update(const AuthState(status: AuthStatus.signedOut));
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }

  Future<void> signOut() async {
    final session = await _store.read();

    if (session == null) {
      await _store.clear();
      _update(const AuthState(status: AuthStatus.signedOut));
      return;
    }

    // The backend must confirm the session is revoked or invalid.
    await _revoke(session.token);

    // Only clear local storage after confirmed server response.
    await _store.clear();

    _update(const AuthState(status: AuthStatus.signedOut));
  }
}
