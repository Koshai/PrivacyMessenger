import '../../features/auth/models/auth_session.dart';

abstract interface class SessionStore {
  Future<void> save(AuthSession session);

  Future<AuthSession?> read();

  Future<void> clear();
}
