import 'package:flutter/material.dart';

import 'message_status.dart';
import 'models/envelope.dart';

/// Status row under a chat bubble: label, detail, and one safe action.
class MessageStatusText extends StatelessWidget {
  const MessageStatusText({
    super.key,
    required this.message,
    required this.onResubmitSame,
  });

  final ChatMessageView message;
  final VoidCallback onResubmitSame;

  @override
  Widget build(BuildContext context) {
    final status = messageStatusFor(
      delivery: message.delivery,
      isMine: message.isMine,
    );
    if (status == null) return const SizedBox.shrink();

    final detail = message.error?.isNotEmpty == true
        ? message.error
        : status.detail;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          status.label,
          style: theme.textTheme.labelSmall,
          semanticsLabel: 'Message status: ${status.label}',
        ),
        if (detail != null && detail.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(detail, style: theme.textTheme.labelSmall),
        ],
        if (status.action == MessageStatusAction.resubmitSame &&
            status.actionLabel != null)
          TextButton(
            onPressed: onResubmitSame,
            child: Text(status.actionLabel!),
          ),
        if (status.action == MessageStatusAction.composeNew)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Use the message box below to write a new message.',
              style: theme.textTheme.labelSmall,
            ),
          ),
      ],
    );
  }
}
