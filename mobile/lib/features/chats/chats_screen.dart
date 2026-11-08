import 'package:flutter/material.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/crypto/mls_session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/ui/app_empty_state.dart';
import '../../core/ui/app_error_panel.dart';
import '../../core/ui/avatar_initials.dart';
import '../../features/friends/models/friend.dart';
import '../calling/call_controller.dart';
import '../messaging/conversation_screen.dart';
import '../messaging/encrypted_conversation_service.dart';
import '../messaging/realtime_client.dart';
import 'chat_list_format.dart';

class _ChatRow {
  const _ChatRow({
    required this.friend,
    this.preview,
  });

  final Friend friend;
  final ChatListPreview? preview;
}

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
  List<_ChatRow> _rows = const [];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    final api = widget.apiClient;
    final auth = widget.authController;
    if (api == null || auth == null) {
      setState(() {
        _loading = false;
        _rows = const [];
      });
      return;
    }
    _refreshing = true;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await auth.sessionToken();
      if (token == null) throw StateError('No session');
      final friends = await api.listFriends(token);
      final myUserId = auth.state.userId ?? '';
      final messaging = widget.messaging;
      final rows = <_ChatRow>[];
      for (final friend in friends) {
        ChatListPreview? preview;
        if (messaging != null && myUserId.isNotEmpty) {
          try {
            preview = await messaging.previewForPeer(
              peerUserId: friend.userId,
              myUserId: myUserId,
            );
          } catch (_) {
            preview = null;
          }
        }
        rows.add(_ChatRow(friend: friend, preview: preview));
      }
      rows.sort((a, b) {
        final at = a.preview?.createdAt;
        final bt = b.preview?.createdAt;
        if (at == null && bt == null) {
          return a.friend.email.compareTo(b.friend.email);
        }
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Unable to load conversations';
      });
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            tooltip: 'Refresh chats',
            onPressed: _refreshing ? null : _refresh,
            icon: const Icon(Icons.refresh, semanticLabel: 'Refresh chats'),
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
    if (_rows.isEmpty) {
      return AppEmptyState(
        icon: Icons.chat_bubble_outline,
        title: 'No conversations yet',
        message:
            'Add a friend from the Friends tab, then open their chat here '
            'to send encrypted messages or start a call.',
        actionLabel: widget.onOpenFriends == null ? null : 'Add friends',
        onAction: widget.onOpenFriends,
      );
    }

    return ListView.separated(
      itemCount: _rows.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final row = _rows[index];
        final friend = row.friend;
        final preview = row.preview;
        final title = chatDisplayName(friend.email);
        final subtitle = preview?.subtitle ?? 'Encrypted chat';
        return ListTile(
          leading: InitialsAvatar(email: friend.email, label: title),
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: preview?.timeLabel == null
              ? null
              : Text(
                  preview!.timeLabel!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
          onTap: () {
            final api = widget.apiClient;
            final auth = widget.authController;
            final mls = widget.mls;
            if (api == null || auth == null || mls == null) return;
            Navigator.of(context)
                .push(
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
            )
                .then((_) {
              if (mounted) _refresh();
            });
          },
        );
      },
    );
  }
}
