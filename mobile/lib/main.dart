import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'core/auth/auth_controller.dart';
import 'core/auth/auth_state.dart';
import 'core/auth/secure_session_store.dart';
import 'core/crypto/device_crypto_store.dart';
import 'core/crypto/license_notices.dart';
import 'core/crypto/mls_session_manager.dart';
import 'core/network/api_client.dart';
import 'core/network/api_config.dart';
import 'core/theme/app_theme.dart';
import 'core/ui/app_error_panel.dart';

import 'features/calling/call_auth.dart';
import 'features/calling/call_auth_session.dart';
import 'features/calling/call_binding_inbox.dart';
import 'features/calling/call_key_binding.dart';
import 'features/messaging/encrypted_conversation_service.dart';
import 'features/messaging/local_message_store.dart';
import 'features/calling/call_platform.dart';
import 'features/calling/call_controller.dart';
import 'features/calling/call_screens.dart';
import 'features/calling/calling_api_client.dart';
import 'features/calling/webrtc_call_service.dart';
import 'features/chats/chats_screen.dart';
import 'features/chats/conversation_peer_index.dart';
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
            home = const _CheckingSignInSplash();
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
              body: AppErrorPanel(
                title: 'Can’t reach Private Messenger',
                message:
                    'We couldn’t confirm your saved sign-in. '
                    'Check your internet connection and try again. '
                    'If this keeps happening, clear the saved sign-in on this '
                    'device and sign in again.',
                primaryLabel: 'Try again',
                onPrimary: _authController.restore,
                secondaryLabel: 'Clear saved sign-in',
                onSecondary: () {
                  unawaited(_authController.clearLocalSession());
                },
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
  LocalMessageStore? _history;
  EncryptedConversationService? _messaging;
  bool _historyUnavailable = false;
  bool _shellDisposed = false;
  String _token = '';
  String? _cachedCallAuthFingerprintHex;
  CallAuthStore? _callAuthStore;

  @override
  void initState() {
    super.initState();
    _bindingInbox = CallBindingInbox();
    unawaited(_openMessaging());
    final base = ApiConfig.baseUri;
    _realtime = RealtimeClient(
      wsBaseUri: base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '/realtime/ws',
      ),
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
        final fingerprint = await _callAuthFingerprint(userId: userId, deviceId: deviceId);
        if (fingerprint == null) {
          return const CallAuthOutcome(
            phase: CallAuthPhase.failed,
            error: 'No messaging identity for this device',
          );
        }
        _calls.localSafetyFingerprintHex = fingerprint;
        final pipeline = _messaging;
        if (pipeline == null) {
          return const CallAuthOutcome(
            phase: CallAuthPhase.failed,
            error: 'Encrypted history is not available',
          );
        }
        final channel = MlsCallKeyChannel(
          api: widget.apiClient,
          mls: widget.mls,
          token: () => _token,
          pipeline: pipeline,
          inbox: _bindingInbox,
          myUserId: () => widget.authController.state.userId ?? '',
          ensureMls: () async {
            await widget.mls.ensureReady(widget.authController);
          },
        );
        return CallAuthSession(
          api: callingApi,
          token: () => _token,
          userId: userId,
          deviceId: deviceId,
          localMlsFingerprintHex: fingerprint,
          bindingExchange: channel.exchange,
          deviceStillEnrolled: (peerUser, peerDevice) =>
              _peerEnrolled(peerUser, peerDevice),
          store: _callAuthStore ??= SecureCallAuthStore(),
        ).run(request);
      },
      warmCallAuth: () async {
        final userId = widget.authController.state.userId ?? '';
        final deviceId = widget.authController.state.deviceId ?? '';
        final fingerprint = await _callAuthFingerprint(userId: userId, deviceId: deviceId);
        if (fingerprint == null) return;
        await CallAuthSession(
          api: callingApi,
          token: () => _token,
          userId: userId,
          deviceId: deviceId,
          localMlsFingerprintHex: fingerprint,
          store: _callAuthStore ??= SecureCallAuthStore(),
        ).warmKeyPair();
      },
      recheckEnrollment: (peerUser, peerDevice) => _peerEnrolled(peerUser, peerDevice),
      clearLocalSecrets: () async {
        final userId = widget.authController.state.userId ?? '';
        final deviceId = widget.authController.state.deviceId ?? '';
        await clearLocalCallSecret(userId: userId, deviceId: deviceId);
        await _bindingInbox.clear();
        _cachedCallAuthFingerprintHex = null;
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

  Future<void> _openMessaging() async {
    final userId = widget.authController.state.userId;
    final deviceId = widget.authController.state.deviceId;
    if (userId == null || deviceId == null) {
      if (mounted) setState(() => _historyUnavailable = true);
      return;
    }
    try {
      final directory = await getApplicationSupportDirectory();
      final path = LocalMessageStore.databasePath(
        directory: directory.path,
        userId: userId,
        deviceId: deviceId,
      );
      final history = await LocalMessageStore.open(
        userId: userId,
        deviceId: deviceId,
        dbPath: path,
      );
      if (!mounted || _shellDisposed) {
        await history.close();
        return;
      }
      _history = history;
      if (_shellDisposed) {
        await history.close();
        _history = null;
        return;
      }
      final peerIndex = ConversationPeerIndex(
        path: ConversationPeerIndex.pathBesideDatabase(path),
      );
      await peerIndex.load();
      if (!mounted || _shellDisposed) {
        await history.close();
        _history = null;
        return;
      }
      setState(() {
        _messaging = EncryptedConversationService(
          api: widget.apiClient,
          mls: widget.mls,
          inbox: _bindingInbox,
          history: history,
          peerIndex: peerIndex,
        );
      });
    } catch (_) {
      if (mounted && !_shellDisposed) {
        setState(() => _historyUnavailable = true);
      }
    }
  }

  Future<void> _bootstrap() async {
    _token = await widget.authController.sessionToken() ?? '';
    if (_token.isNotEmpty) {
      await _realtime.start(_token);
      await _calls.startListening();
    }
  }

  Future<String?> _callAuthFingerprint({
    required String userId,
    required String deviceId,
  }) async {
    final cached = _cachedCallAuthFingerprintHex;
    if (cached != null && cached.isNotEmpty) return cached;
    final record = await DeviceCryptoStore().read(userId: userId, deviceId: deviceId);
    final hex = record?.fingerprintHex;
    if (hex == null || hex.isEmpty) return null;
    _cachedCallAuthFingerprintHex = hex;
    return hex;
  }

  @override
  void dispose() {
    _shellDisposed = true;
    final history = _history;
    if (history != null) {
      _history = null;
      unawaited(history.close());
    }
    _calls.dispose();
    _realtime.dispose();
    super.dispose();
  }

  void _retryOpenMessaging() {
    if (_shellDisposed) return;
    setState(() {
      _historyUnavailable = false;
      _messaging = null;
    });
    unawaited(_openMessaging());
  }

  @override
  Widget build(BuildContext context) {
    if (_historyUnavailable) {
      return Scaffold(
        body: AppErrorPanel(
          icon: Icons.lock_outline,
          title: 'Encrypted history unavailable',
          message:
              'Private Messenger couldn’t open your encrypted conversation '
              'history on this device. Your messages were not deleted. '
              'Try again, or log out if you need to leave this screen.',
          primaryLabel: 'Try again',
          onPrimary: _retryOpenMessaging,
          secondaryLabel: 'Log out',
          onSecondary: () {
            unawaited(widget.onLogout());
          },
        ),
      );
    }
    final messaging = _messaging;
    if (messaging == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
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
        messaging: messaging,
        callController: _calls,
        realtime: _realtime,
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
  final RealtimeClient? realtime;

  const MainNavigation({
    super.key,
    this.onLogout,
    this.apiClient,
    this.authController,
    this.mls,
    this.messaging,
    this.callController,
    this.realtime,
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
        realtime: widget.realtime,
        onOpenFriends: () {
          setState(() => selectedIndex = 1);
        },
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

/// Lightweight branded wait state while session restore runs.
class _CheckingSignInSplash extends StatelessWidget {
  const _CheckingSignInSplash();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  'Private Messenger',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Checking sign-in…',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                const CircularProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
