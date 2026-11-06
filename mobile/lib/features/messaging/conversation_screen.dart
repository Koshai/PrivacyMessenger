import 'package:flutter/material.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/crypto/mls_session_manager.dart';
import '../../core/network/api_client.dart';
import '../calling/call_controller.dart';
import '../calling/models/call_session.dart';
import 'conversation_controller.dart';
import 'encrypted_conversation_service.dart';
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

  @override
  void initState() {
    super.initState();
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

  @override
  void dispose() {
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
          appBar: AppBar(
            title: Text(widget.peerEmail),
            actions: [
              if (widget.callController != null) ...[
                IconButton(
                  tooltip: 'Audio call',
                  icon: const Icon(Icons.call),
                  onPressed: () => widget.callController!.startOutgoing(
                    peerUserId: widget.peerUserId,
                    mediaType: CallMediaType.audio,
                  ),
                ),
                IconButton(
                  tooltip: 'Video call',
                  icon: const Icon(Icons.videocam),
                  onPressed: () => widget.callController!.startOutgoing(
                    peerUserId: widget.peerUserId,
                    mediaType: CallMediaType.video,
                  ),
                ),
              ],
              if (_controller.offline)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: Icon(Icons.cloud_off, semanticLabel: 'Offline'),
                ),
            ],
          ),
          body: Column(
            children: [
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
                          decoration: const InputDecoration(
                            hintText: 'Message',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Send',
                        onPressed: _controller.loadState ==
                                ConversationLoadState.ready
                            ? _submit
                            : null,
                        icon: const Icon(Icons.send),
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

  Widget _buildBody() {
    switch (_controller.loadState) {
      case ConversationLoadState.loading:
      case ConversationLoadState.idle:
        return const Center(child: CircularProgressIndicator());
      case ConversationLoadState.error:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_controller.errorMessage ?? 'Error'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _controller.open,
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      case ConversationLoadState.ready:
        if (_controller.messages.isEmpty) {
          return const Center(child: Text('No messages yet'));
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
    final text = _input.text;
    _input.clear();
    await _controller.send(text);
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
    final status = deliveryStatusLabel(
      delivery: message.delivery,
      isMine: message.isMine,
    );

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
                if (message.error != null && message.error!.isNotEmpty) ...[
                  Text(
                    message.error!,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const SizedBox(height: 6),
                ],
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (status != null)
                      Text(
                        status,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    if (message.isMine &&
                        message.delivery == ChatDeliveryState.failed) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: onRetry,
                        child: const Text('Retry'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
