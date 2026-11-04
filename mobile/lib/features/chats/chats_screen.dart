import 'package:flutter/material.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/crypto/mls_session_manager.dart';
import '../../core/network/api_client.dart';
import '../../features/friends/models/friend.dart';
import '../messaging/conversation_screen.dart';

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({
    super.key,
    this.apiClient,
    this.authController,
    this.mls,
  });

  final ApiClient? apiClient;
  final AuthController? authController;
  final MlsSessionManager? mls;

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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            FilledButton(onPressed: _refresh, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_friends.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline, size: 72),
              SizedBox(height: 20),
              Text(
                'No conversations yet',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 12),
              Text(
                'Add a friend to start a conversation.',
                style: TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
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
                ),
              ),
            );
          },
        );
      },
    );
  }
}
