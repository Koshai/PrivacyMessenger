import 'package:flutter/material.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/crypto/mls_session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/ui/app_empty_state.dart';
import '../../core/ui/app_error_panel.dart';
import '../../features/friends/models/friend.dart';
import '../calling/call_controller.dart';
import '../messaging/conversation_screen.dart';
import '../messaging/encrypted_conversation_service.dart';
import '../messaging/realtime_client.dart';

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({
    super.key,
    this.apiClient,
    this.authController,
    this.mls,
    this.messaging,
    this.callController,
    this.realtime,
    this.onOpenFriends,
  });

  final ApiClient? apiClient;
  final AuthController? authController;
  final MlsSessionManager? mls;
  final EncryptedConversationService? messaging;
  final CallController? callController;
  final RealtimeClient? realtime;

  /// Switches to the Friends tab (provided by [MainNavigation]).
  final VoidCallback? onOpenFriends;

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  List<Friend> _friends = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final api = widget.apiClient;
    final auth = widget.authController;
    if (api == null || auth == null) {
      setState(() {
        _loading = false;
        _friends = const [];
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await auth.sessionToken();
      if (token == null) throw StateError('No session');
      final friends = await api.listFriends(token);
      if (!mounted) return;
      setState(() {
        _friends = friends;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Unable to load conversations';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Chats',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppErrorPanel(
        title: 'Conversations unavailable',
        message: _error!,
        primaryLabel: 'Retry',
        onPrimary: _refresh,
      );
    }
    if (_friends.isEmpty) {
      return AppEmptyState(
        icon: Icons.chat_bubble_outline,
        title: 'No conversations yet',
        message: 'Add a friend to start an encrypted conversation.',
        actionLabel: widget.onOpenFriends == null ? null : 'Add friends',
        onAction: widget.onOpenFriends,
      );
    }

    return ListView.separated(
      itemCount: _friends.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final friend = _friends[index];
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person)),
          title: Text(friend.email),
          subtitle: const Text('Encrypted chat'),
          onTap: () {
            final api = widget.apiClient;
            final auth = widget.authController;
            final mls = widget.mls;
            if (api == null || auth == null || mls == null) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ConversationScreen(
                  apiClient: api,
                  authController: auth,
                  mls: mls,
                  peerUserId: friend.userId,
                  peerEmail: friend.email,
                  messaging: widget.messaging,
                  callController: widget.callController,
                  realtime: widget.realtime,
                ),
              ),
            );
          },
        );
      },
    );
  }
}
