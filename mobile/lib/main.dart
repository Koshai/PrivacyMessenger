import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'core/auth/auth_controller.dart';
import 'core/auth/auth_state.dart';
import 'core/auth/secure_session_store.dart';
import 'core/crypto/device_crypto_store.dart';
import 'core/crypto/license_notices.dart';
import 'core/crypto/mls_session_manager.dart';
import 'core/network/api_client.dart';
import 'core/network/api_config.dart';
import 'core/theme/app_theme.dart';

import 'features/calling/call_auth.dart';
import 'features/calling/call_auth_session.dart';
import 'features/calling/call_binding_inbox.dart';
import 'features/calling/call_key_binding.dart';
import 'features/messaging/encrypted_conversation_service.dart';
import 'features/calling/call_platform.dart';
import 'features/calling/call_controller.dart';
import 'features/calling/call_screens.dart';
import 'features/calling/calling_api_client.dart';
import 'features/calling/webrtc_call_service.dart';
import 'features/chats/chats_screen.dart';
import 'features/friends/friends_screen.dart';
import 'features/messaging/realtime_client.dart';
import 'features/settings/settings_screen.dart';
import 'features/auth/auth_flow.dart';

void main() {
  registerCryptoLicenseNotices();
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
  late final MlsSessionManager _mls;

  @override
  void initState() {
    super.initState();

    _httpClient = http.Client();

    _apiClient = ApiClient(client: _httpClient, baseUri: ApiConfig.baseUri);
    _mls = MlsSessionManager();

    _authController = AuthController(
      store: SecureSessionStore(),
      validate: _apiClient.getAuthenticatedUser,
      revoke: _apiClient.logout,
    );

    _authController.restore();
  }

  @override
  void dispose() {
    _mls.close();
    _authController.dispose();
    _httpClient.close();
    super.dispose();
  }

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
            home = _AuthenticatedShell(
              apiClient: _apiClient,
              authController: _authController,
              mls: _mls,
              onLogout: () async {
                final userId = _authController.state.userId;
                final deviceId = _authController.state.deviceId;
                if (userId != null && deviceId != null) {
                  await _mls.clearOnLogout(userId: userId, deviceId: deviceId);
                }
                await _authController.signOut();
              },
            );
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

class _AuthenticatedShell extends StatefulWidget {
  const _AuthenticatedShell({
    required this.apiClient,
    required this.authController,
    required this.mls,
    required this.onLogout,
  });

  final ApiClient apiClient;
  final AuthController authController;
  final MlsSessionManager mls;
  final Future<void> Function() onLogout;

  @override
  State<_AuthenticatedShell> createState() => _AuthenticatedShellState();
}

class _AuthenticatedShellState extends State<_AuthenticatedShell> {
  late final CallController _calls;
  late final RealtimeClient _realtime;
  late final CallBindingInbox _bindingInbox;
  late final EncryptedConversationService _messaging;
  String _token = '';

  @override
  void initState() {
    super.initState();
    _bindingInbox = CallBindingInbox();
    _messaging = EncryptedConversationService(
      api: widget.apiClient,
      mls: widget.mls,
      inbox: _bindingInbox,
    );
    final base = ApiConfig.baseUri;
    _realtime = RealtimeClient(
      wsBaseUri: base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws'),
    );
    final callingApi = CallingApiClient(client: http.Client(), baseUri: base);
    const relayOnly = bool.fromEnvironment('CALL_RELAY_ONLY');
    final authState = widget.authController.state;
    _calls = CallController(
      api: callingApi,
      media: WebRtcCallService(
        relayOnly: relayOnly,
        loadIceConfig: () => callingApi.iceConfig(
          token: _token,
          relayOnly: relayOnly,
        ),
      ),
      myUserId: authState.userId ?? '',
      tokenProvider: () => _token,
      realtime: _realtime,
      authenticatePeer: (request) async {
        final userId = widget.authController.state.userId ?? '';
        final deviceId = widget.authController.state.deviceId ?? '';
        final record = await DeviceCryptoStore().read(userId: userId, deviceId: deviceId);
        if (record == null) {
          return const CallAuthOutcome(
            phase: CallAuthPhase.failed,
            error: 'No messaging identity for this device',
          );
        }
        _calls.localSafetyFingerprintHex = record.fingerprintHex;
        final channel = MlsCallKeyChannel(
          api: widget.apiClient,
          mls: widget.mls,
          token: () => _token,
          pipeline: _messaging,
          inbox: _bindingInbox,
          myUserId: () => widget.authController.state.userId ?? '',
        );
        return CallAuthSession(
          api: callingApi,
          token: () => _token,
          userId: userId,
          deviceId: deviceId,
          localMlsFingerprintHex: record.fingerprintHex,
          bindingExchange: channel.exchange,
          deviceStillEnrolled: (peerUser, peerDevice) =>
              _peerEnrolled(peerUser, peerDevice),
        ).run(request);
      },
      recheckEnrollment: (peerUser, peerDevice) => _peerEnrolled(peerUser, peerDevice),
      clearLocalSecrets: () async {
        final userId = widget.authController.state.userId ?? '';
        final deviceId = widget.authController.state.deviceId ?? '';
        await clearLocalCallSecret(userId: userId, deviceId: deviceId);
        await _bindingInbox.clear();
      },
    );
    _calls.onLifecycle = CallPlatformBridge.instance.show;
    CallPlatformBridge.instance.bind(onSystemEnded: () {
      _calls.hangUp();
    });
    unawaited(_bootstrap());
  }

  Future<bool> _peerEnrolled(String peerUser, String peerDevice) async {
    final listed = await widget.apiClient.peerIdentities(
      token: _token,
      peerUserId: peerUser,
    );
    return listed.any((e) => e.deviceId == peerDevice);
  }

  Future<void> _bootstrap() async {
    _token = await widget.authController.sessionToken() ?? '';
    if (_token.isNotEmpty) {
      await _realtime.start(_token);
      await _calls.startListening();
    }
  }

  @override
  void dispose() {
    _calls.dispose();
    _realtime.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallHost(
      controller: _calls,
      child: MainNavigation(
        onLogout: () async {
          await _calls.onLogout();
          await widget.onLogout();
        },
        apiClient: widget.apiClient,
        authController: widget.authController,
        mls: widget.mls,
        messaging: _messaging,
        callController: _calls,
      ),
    );
  }
}

class MainNavigation extends StatefulWidget {
  final Future<void> Function()? onLogout;
  final ApiClient? apiClient;
  final AuthController? authController;
  final MlsSessionManager? mls;
  final EncryptedConversationService? messaging;
  final CallController? callController;

  const MainNavigation({
    super.key,
    this.onLogout,
    this.apiClient,
    this.authController,
    this.mls,
    this.messaging,
    this.callController,
  });

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final screens = [
      ChatsScreen(
        apiClient: widget.apiClient,
        authController: widget.authController,
        mls: widget.mls,
        messaging: widget.messaging,
        callController: widget.callController,
      ),
      FriendsScreen(
        apiClient: widget.apiClient,
        authController: widget.authController,
      ),
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
