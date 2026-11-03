import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'core/auth/auth_controller.dart';
import 'core/auth/auth_state.dart';
import 'core/auth/secure_session_store.dart';
import 'core/network/api_client.dart';
import 'core/network/api_config.dart';
import 'core/theme/app_theme.dart';

import 'features/chats/chats_screen.dart';
import 'features/friends/friends_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/auth/auth_flow.dart';

void main() {
  runApp(const PrivateMessengerApp());
}

class PrivateMessengerApp extends StatefulWidget {
  const PrivateMessengerApp({super.key});

  @override
  State<PrivateMessengerApp> createState() => _PrivateMessengerAppState();
}

class _PrivateMessengerAppState extends State<PrivateMessengerApp> {
  late final http.Client _httpClient;
  late final ApiClient _apiClient;
  late final AuthController _authController;

  @override
  void initState() {
    super.initState();

    _httpClient = http.Client();

    _apiClient = ApiClient(client: _httpClient, baseUri: ApiConfig.baseUri);

    _authController = AuthController(
      store: SecureSessionStore(),
      validate: _apiClient.getAuthenticatedUser,
      revoke: _apiClient.logout,
    );

    _authController.restore();
  }

  @override
  void dispose() {
    _authController.dispose();
    _httpClient.close();
    super.dispose();
  }

  @override
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _authController,
      builder: (context, _) {
        final state = _authController.state;

        Widget home;

        switch (state.status) {
          case AuthStatus.initial:
          case AuthStatus.checking:
            home = const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
            break;

          case AuthStatus.authenticated:
            home = MainNavigation(onLogout: _authController.signOut);
            break;

          case AuthStatus.signedOut:
            home = AuthFlow(
              apiClient: _apiClient,
              authController: _authController,
            );
            break;

          case AuthStatus.unavailable:
            home = Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: _authController.restore,
                  child: const Text('Try again'),
                ),
              ),
            );
            break;
        }

        return MaterialApp(
          key: ValueKey(state.status),
          title: 'Private Messenger',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          home: home,
        );
      },
    );
  }
}

class MainNavigation extends StatefulWidget {
  final Future<void> Function()? onLogout;

  const MainNavigation({super.key, this.onLogout});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    // Create screens here so widget.onLogout is accessible.
    final screens = [
      const ChatsScreen(),
      const FriendsScreen(),
      SettingsScreen(onLogout: widget.onLogout),
    ];

    return Scaffold(
      body: IndexedStack(index: selectedIndex, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) {
          setState(() => selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Friends',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
