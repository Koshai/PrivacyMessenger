import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:private_messenger/core/auth/auth_controller.dart';
import 'package:private_messenger/core/auth/session_store.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/auth/models/auth_identity.dart';
import 'package:private_messenger/features/auth/models/auth_session.dart';
import 'package:private_messenger/features/auth/verify_otp_screen.dart';

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
  late http.Client client;
  late ApiClient api;
  late AuthController controller;

  setUp(() {
    client = MockClient((request) async {
      throw StateError('Unexpected HTTP request');
    });

    api = ApiClient(
      client: client,
      baseUri: Uri.parse('http://localhost:4000'),
    );

    controller = AuthController(
      store: FakeSessionStore(),
      validate: (_) async => AuthIdentity(
        userId: 'user-1',
        deviceId: 'device-1',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      ),
      revoke: (_) async {},
    );
  });

  tearDown(() {
    controller.dispose();
    client.close();
  });

  Widget createWidget() => MaterialApp(
    home: VerifyOtpScreen(
      email: 'test@example.com',
      challengeId: '550e8400-e29b-41d4-a716-446655440000',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      apiClient: api,
      authController: controller,
    ),
  );

  testWidgets('renders verification screen', (tester) async {
    await tester.pumpWidget(createWidget());

    expect(find.text('Enter your verification code'), findsOneWidget);
    expect(find.textContaining('test@example.com'), findsOneWidget);
    expect(find.text('Verify code'), findsOneWidget);
  });

  testWidgets('rejects incomplete OTP', (tester) async {
    await tester.pumpWidget(createWidget());

    await tester.enterText(find.byType(TextFormField), '123');

    await tester.tap(find.text('Verify code'));
    await tester.pump();

    expect(find.text('Enter a valid six-digit code'), findsOneWidget);
  });

  testWidgets('accepts only numeric input', (tester) async {
    await tester.pumpWidget(createWidget());

    await tester.enterText(find.byType(TextFormField), '12ab34');

    expect(find.text('1234'), findsOneWidget);
  });
}
