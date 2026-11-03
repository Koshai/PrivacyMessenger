import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:private_messenger/core/auth/auth_controller.dart';
import 'package:private_messenger/core/auth/auth_state.dart';
import 'package:private_messenger/core/auth/session_store.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/auth/auth_flow.dart';
import 'package:private_messenger/features/auth/models/auth_identity.dart';
import 'package:private_messenger/features/auth/models/auth_session.dart';
import 'package:private_messenger/features/chats/chats_screen.dart';
import 'package:private_messenger/main.dart';

class FakeSessionStore implements SessionStore {
  AuthSession? session;

  @override
  Future<void> save(AuthSession value) async => session = value;

  @override
  Future<AuthSession?> read() async => session;

  @override
  Future<void> clear() async => session = null;
}

class _AuthShellHarness extends StatefulWidget {
  final AuthController authController;
  final ApiClient apiClient;

  const _AuthShellHarness({
    required this.authController,
    required this.apiClient,
  });

  @override
  State<_AuthShellHarness> createState() => _AuthShellHarnessState();
}

class _AuthShellHarnessState extends State<_AuthShellHarness> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.authController,
      builder: (context, _) {
        final state = widget.authController.state;

        Widget home;
        switch (state.status) {
          case AuthStatus.initial:
          case AuthStatus.checking:
            home = const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          case AuthStatus.authenticated:
            home = MainNavigation(onLogout: widget.authController.signOut);
          case AuthStatus.signedOut:
            home = AuthFlow(
              apiClient: widget.apiClient,
              authController: widget.authController,
            );
          case AuthStatus.unavailable:
            home = Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: widget.authController.restore,
                  child: const Text('Try again'),
                ),
              ),
            );
        }

        return MaterialApp(
          key: ValueKey(state.status),
          home: home,
        );
      },
    );
  }
}

void main() {
  AuthSession session() => AuthSession(
    userId: 'user-1',
    deviceId: 'device-1',
    token: 'token-1',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );

  AuthIdentity identity() => AuthIdentity(
    userId: 'user-1',
    deviceId: 'device-1',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );

  testWidgets('login replaces AuthFlow with Chats shell', (tester) async {
    final client = MockClient((_) async => http.Response('{}', 500));
    final api = ApiClient(
      client: client,
      baseUri: Uri.parse('http://localhost:4000'),
    );
    final store = FakeSessionStore();
    final controller = AuthController(
      store: store,
      validate: (_) async => identity(),
      revoke: (_) async {},
    );
    addTearDown(() {
      controller.dispose();
      client.close();
    });

    await tester.pumpWidget(
      _AuthShellHarness(authController: controller, apiClient: api),
    );

    await controller.restore();
    await tester.pumpAndSettle();
    expect(find.text('Send verification code'), findsOneWidget);

    await controller.signIn(session());
    await tester.pumpAndSettle();

    expect(find.byType(ChatsScreen), findsOneWidget);
    expect(find.text('No conversations yet'), findsOneWidget);
    expect(find.text('Send verification code'), findsNothing);
  });

  testWidgets('authenticated shell cannot pop back to OTP', (tester) async {
    final client = MockClient((_) async => http.Response('{}', 500));
    final api = ApiClient(
      client: client,
      baseUri: Uri.parse('http://localhost:4000'),
    );
    final controller = AuthController(
      store: FakeSessionStore(),
      validate: (_) async => identity(),
      revoke: (_) async {},
    );
    addTearDown(() {
      controller.dispose();
      client.close();
    });

    await tester.pumpWidget(
      _AuthShellHarness(authController: controller, apiClient: api),
    );

    await controller.restore();
    await tester.pumpAndSettle();

    // Push OTP onto the signed-out AuthFlow navigator.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          body: Text('OTP screen stub'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('OTP screen stub'), findsOneWidget);

    await controller.signIn(session());
    await tester.pumpAndSettle();

    expect(find.byType(ChatsScreen), findsOneWidget);
    expect(find.text('OTP screen stub'), findsNothing);

    // System back must not resurrect the OTP route after MaterialApp key swap.
    final rootNavigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    expect(rootNavigator.canPop(), isFalse);
  });

  testWidgets('settings logout returns to sign-in', (tester) async {
    final client = MockClient((_) async => http.Response('{}', 500));
    final api = ApiClient(
      client: client,
      baseUri: Uri.parse('http://localhost:4000'),
    );
    final store = FakeSessionStore()..session = session();
    final controller = AuthController(
      store: store,
      validate: (_) async => identity(),
      revoke: (_) async {},
    );
    addTearDown(() {
      controller.dispose();
      client.close();
    });

    await tester.pumpWidget(
      _AuthShellHarness(authController: controller, apiClient: api),
    );

    await controller.restore();
    await tester.pumpAndSettle();
    expect(find.byType(ChatsScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    expect(find.text('Send verification code'), findsOneWidget);
    expect(store.session, isNull);
  });
}
