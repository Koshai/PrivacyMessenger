import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../features/auth/models/auth_session.dart';
import 'session_store.dart';

class SecureSessionStore implements SessionStore {
  static const _sessionKey = 'auth_session_v1';

  final FlutterSecureStorage _storage;

  SecureSessionStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // v11 defaults to Keystore-backed AES-GCM (no EncryptedSharedPreferences API).
            aOptions: AndroidOptions(),
          );

  @override
  Future<void> save(AuthSession session) async {
    if (session.isExpired) {
      throw StateError('Cannot save an expired session');
    }

    final data = jsonEncode({
      'user_id': session.userId,
      'device_id': session.deviceId,
      'token': session.token,
      'expires_at': session.expiresAt.toUtc().toIso8601String(),
    });

    await _storage.write(key: _sessionKey, value: data);
  }

  @override
  Future<AuthSession?> read() async {
    final raw = await _storage.read(key: _sessionKey);

    if (raw == null) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid session data');
      }

      final session = AuthSession.fromJson(decoded);

      if (session.isExpired) {
        await clear();
        return null;
      }

      return session;
    } on FormatException {
      await clear();
      return null;
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _sessionKey);
  }
}
