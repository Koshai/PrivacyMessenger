import 'package:flutter/material.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/crypto/mls_session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/ui/app_empty_state.dart';
import '../../core/ui/app_error_panel.dart';
import '../../core/ui/connectivity_banner.dart';
import '../calling/call_controller.dart';
import '../calling/models/call_session.dart';
import 'conversation_controller.dart';
import 'encrypted_conversation_service.dart';
import 'message_status_text.dart';
import 'models/envelope.dart';
import 'realtime_client.dart';

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.apiClient,
    required this.authController,
    required this.mls,
    required this.peerUserId,
    required this.peerEmail,
    this.messaging,
    this.callController,
    this.realtime,
  });

  final ApiClient apiClient;
  final AuthController authController;
  final MlsSessionManager mls;
  final String peerUserId;
  final String peerEmail;
  final EncryptedConversationService? messaging;
  final CallController? callController;
  final RealtimeClient? realtime;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  late final ConversationController _controller;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onDraftChanged);
    _controller = ConversationController(
      api: widget.apiClient,
      auth: widget.authController,
      mls: widget.mls,
      peerUserId: widget.peerUserId,
      peerEmail: widget.peerEmail,
      service: widget.messaging,
      realtime: widget.realtime,
      ownRealtime: widget.realtime == null,
    )..open();
  }

  void _onDraftChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _input.removeListener(_onDraftChanged);
    _input.dispose();
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            title: Text(widget.peerEmail),
            actions: [
              if (widget.callController != null) ...[
                IconButton(
                  tooltip: 'Audio call',
                  icon: const Icon(Icons.call, semanticLabel: 'Audio call'),
                  onPressed: () => widget.callController!.startOutgoing(
                    peerUserId: widget.peerUserId,
                    mediaType: CallMediaType.audio,
                  ),
                ),
                IconButton(
                  tooltip: 'Video call',
                  icon: const Icon(Icons.videocam, semanticLabel: 'Video call'),
                  onPressed: () => widget.callController!.startOutgoing(
                    peerUserId: widget.peerUserId,
                    mediaType: CallMediaType.video,
                  ),
                ),
              ],
            ],
          ),
          body: Column(
            children: [
              ConnectivityBanner(state: _controller.linkState),
              if (_controller.keyChangeWarning != null)
                MaterialBanner(
                  content: Text(_controller.keyChangeWarning!),
                  leading: const Icon(Icons.warning_amber),
                  actions: [
                    TextButton(
                      onPressed: _controller.dismissKeyChangeWarning,
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              Expanded(child: _buildBody()),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _submit(),
                          enabled: !_submitting &&
                              _controller.loadState ==
                                  ConversationLoadState.ready,
                          decoration: const InputDecoration(
                            hintText: 'Message',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Send',
                        onPressed: _canSend ? _submit : null,
                        icon: _submitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send, semanticLabel: 'Send'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  bool get _canSend =>
      !_submitting &&
      _controller.loadState == ConversationLoadState.ready &&
      _input.text.trim().isNotEmpty;

  Widget _buildBody() {
    switch (_controller.loadState) {
      case ConversationLoadState.loading:
      case ConversationLoadState.idle:
        return const Center(child: CircularProgressIndicator());
      case ConversationLoadState.error:
        return AppErrorPanel(
          icon: Icons.lock_outline,
          title: 'Conversation unavailable',
          message: _controller.errorMessage ??
              'Unable to open this conversation right now. '
                  'Your encrypted messages were not deleted.',
          primaryLabel: 'Try again',
          onPrimary: _controller.open,
        );
      case ConversationLoadState.ready:
        if (_controller.messages.isEmpty) {
          return const AppEmptyState(
            icon: Icons.lock_outline,
            title: 'No messages yet',
            message:
                'Messages you send are end-to-end encrypted on this device. '
                'Say hello to start the conversation.',
          );
        }
        return ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(12),
          itemCount: _controller.messages.length,
          itemBuilder: (context, index) {
            final msg = _controller.messages[index];
            return ChatMessageBubble(
              message: msg,
              onRetry: () => _controller.retry(msg.clientMessageId),
            );
          },
        );
    }
  }

  Future<void> _submit() async {
    if (!_canSend) return;
    final text = _input.text;
    setState(() => _submitting = true);
    try {
      await _controller.send(text);
      // Draft clears only after the controller accepted responsibility
      // (optimistic outbox row or durable failure state with bubble text).
      if (mounted && _input.text == text) {
        _input.clear();
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }
}

class ChatMessageBubble extends StatelessWidget {
  const ChatMessageBubble({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final ChatMessageView message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final align =
        message.isMine ? Alignment.centerRight : Alignment.centerLeft;
    final color = message.isMine
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    return Align(
      alignment: align,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        child: Card(
          color: color,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message.plaintext),
                const SizedBox(height: 6),
                MessageStatusText(
                  message: message,
                  onResubmitSame: onRetry,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
