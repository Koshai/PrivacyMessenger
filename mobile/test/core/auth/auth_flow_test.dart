import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:private_messenger/core/auth/auth_controller.dart';
import 'package:private_messenger/core/auth/session_store.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/auth/auth_flow.dart';
import 'package:private_messenger/features/auth/models/auth_identity.dart';
import 'package:private_messenger/features/auth/models/auth_session.dart';

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
  testWidgets('AuthFlow displays login screen', (tester) async {
    final client = MockClient((_) async => http.Response('{}', 500));

    final api = ApiClient(
      client: client,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    final controller = AuthController(
      store: FakeSessionStore(),
      validate: (_) async => AuthIdentity(
        userId: 'user-1',
        deviceId: 'device-1',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      ),
      revoke: (_) async {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AuthFlow(apiClient: api, authController: controller),
      ),
    );

    expect(find.text('Send verification code'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    client.close();
  });
}
