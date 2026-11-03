import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:private_messenger/core/auth/secure_session_store.dart';
import 'package:private_messenger/features/auth/models/auth_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FlutterSecureStorage.setMockInitialValues({});

  final storage = SecureSessionStore(storage: const FlutterSecureStorage());

  AuthSession createSession({bool expired = false}) {
    return AuthSession(
      userId: '11111111-1111-4111-8111-111111111111',
      deviceId: '22222222-2222-4222-8222-222222222222',
      token: 'test-session-token',
      expiresAt: DateTime.now().toUtc().add(
        Duration(minutes: expired ? -5 : 30),
      ),
    );
  }

  setUp(() async {
    await storage.clear();
  });

  test('saves and restores a valid session', () async {
    final session = createSession();

    await storage.save(session);

    final restored = await storage.read();

    expect(restored, isNotNull);
    expect(restored!.token, session.token);
    expect(restored.userId, session.userId);
    expect(restored.deviceId, session.deviceId);
  });

  test('returns null when no session exists', () async {
    final restored = await storage.read();

    expect(restored, isNull);
  });

  test('clears a stored session', () async {
    await storage.save(createSession());

    await storage.clear();

    expect(await storage.read(), isNull);
  });

  test('rejects expired sessions during save', () async {
    final expiredSession = createSession(expired: true);

    await expectLater(storage.save(expiredSession), throwsA(isA<StateError>()));
  });
}
