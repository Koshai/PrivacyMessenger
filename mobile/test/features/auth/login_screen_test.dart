import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:private_messenger/core/auth/auth_controller.dart';
import 'package:private_messenger/core/auth/session_store.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/auth/login_screen.dart';
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
  late http.Client client;
  late AuthController controller;
  late ApiClient api;

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
    home: LoginScreen(apiClient: api, authController: controller),
  );

  testWidgets('renders login screen', (tester) async {
    await tester.pumpWidget(createWidget());

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Email address'), findsOneWidget);
    expect(find.text('Send verification code'), findsOneWidget);
  });

  testWidgets('requires valid email', (tester) async {
    await tester.pumpWidget(createWidget());

    await tester.tap(find.text('Send verification code'));
    await tester.pump();

    expect(find.text('Email is required'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'invalid-email');

    await tester.tap(find.text('Send verification code'));
    await tester.pump();

    expect(find.text('Enter a valid email'), findsOneWidget);
  });
}
