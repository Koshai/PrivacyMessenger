import '../messaging/local_message_store.dart';

/// One row’s subtitle + trailing time for the chats list.
class ChatListPreview {
  const ChatListPreview({
    required this.subtitle,
    required this.createdAt,
    this.timeLabel,
  });

  final String subtitle;
  final DateTime createdAt;
  final String? timeLabel;
}

/// Local-part of an email, or the full address when there is no `@`.
String chatDisplayName(String email) {
  final trimmed = email.trim();
  if (trimmed.isEmpty) return 'Unknown';
  final at = trimmed.indexOf('@');
  if (at <= 0) return trimmed;
  return trimmed.substring(0, at);
}

/// Relative / short absolute time for list rows. [now] is injectable for tests.
String formatChatListTime(DateTime when, {DateTime? now}) {
  final local = when.toLocal();
  final anchor = (now ?? DateTime.now()).toLocal();
  final today = DateTime(anchor.year, anchor.month, anchor.day);
  final day = DateTime(local.year, local.month, local.day);
  final deltaDays = today.difference(day).inDays;

  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  final clock = '$hh:$mm';

  if (deltaDays == 0) return clock;
  if (deltaDays == 1) return 'Yesterday';
  if (deltaDays > 1 && deltaDays < 7) {
    const weekdays = [
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun',
    ];
    return weekdays[local.weekday - 1];
  }
  final mo = local.month.toString().padLeft(2, '0');
  final dy = local.day.toString().padLeft(2, '0');
  if (local.year == anchor.year) return '$mo/$dy';
  return '$mo/$dy/${local.year}';
}

String _truncatePreview(String text, {int maxChars = 72}) {
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= maxChars) return collapsed;
  return '${collapsed.substring(0, maxChars - 1)}…';
}

/// Builds list subtitle from a decrypted local row. Never invents unread counts.
ChatListPreview chatListPreviewFromRecord(
  LocalMessageRecord record, {
  required String myUserId,
  DateTime? now,
}) {
  final mine = record.senderId == myUserId;
  final body = _truncatePreview(record.plaintext);
  final statusPrefix = switch (record.delivery) {
    LocalMessageDelivery.sending ||
    LocalMessageDelivery.preparing ||
    LocalMessageDelivery.encrypting ||
    LocalMessageDelivery.ready ||
    LocalMessageDelivery.submitting =>
      'Sending… ',
    LocalMessageDelivery.failed => 'Couldn’t send · ',
    LocalMessageDelivery.uncertain => 'Not confirmed · ',
    LocalMessageDelivery.blocked => 'Can’t resend · ',
    LocalMessageDelivery.sent ||
    LocalMessageDelivery.received =>
      '',
  };

  final direction = mine ? 'You: ' : '';
  final subtitle = body.isEmpty
      ? (mine ? 'You sent a message' : 'Message received')
      : '$statusPrefix$direction$body';

  return ChatListPreview(
    subtitle: subtitle,
    createdAt: record.createdAt,
    timeLabel: formatChatListTime(record.createdAt, now: now),
  );
}
