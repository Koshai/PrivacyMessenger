import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chats/chat_list_format.dart';
import 'package:private_messenger/features/messaging/local_message_store.dart';

LocalMessageRecord _record({
  required String plaintext,
  required String senderId,
  required DateTime createdAt,
  LocalMessageDelivery delivery = LocalMessageDelivery.sent,
}) {
  return LocalMessageRecord(
    ownerUserId: 'me',
    ownerDeviceId: 'dev',
    conversationId: 'c1',
    senderId: senderId,
    clientMessageId: 'm1',
    envelopeId: 'e1',
    conversationSeq: 1,
    createdAtRaw: createdAt.toUtc().toIso8601String(),
    delivery: delivery,
    mlsPhase: null,
    plaintext: plaintext,
  );
}

void main() {
  test('display name uses email local part', () {
    expect(chatDisplayName('alice@example.com'), 'alice');
    expect(chatDisplayName('no-at-sign'), 'no-at-sign');
    expect(
      chatDisplayName('verylonglocalpartnameforellipsis@example.com'),
      'verylonglocalpartnameforellipsis',
    );
  });

  test('timestamp formatting covers today yesterday weekday and date', () {
    final now = DateTime(2026, 11, 7, 15, 30);
    expect(
      formatChatListTime(DateTime(2026, 11, 7, 9, 5), now: now),
      '09:05',
    );
    expect(
      formatChatListTime(DateTime(2026, 11, 6, 9, 5), now: now),
      'Yesterday',
    );
    expect(
      formatChatListTime(DateTime(2026, 11, 3, 9, 5), now: now),
      'Tue',
    );
    expect(
      formatChatListTime(DateTime(2026, 9, 1, 9, 5), now: now),
      '09/01',
    );
    expect(
      formatChatListTime(DateTime(2025, 9, 1, 9, 5), now: now),
      '09/01/2025',
    );
  });

  test('outgoing and failed previews are honest', () {
    final now = DateTime(2026, 11, 7, 12);
    final sent = chatListPreviewFromRecord(
      _record(
        plaintext: 'Hello there friend',
        senderId: 'me',
        createdAt: DateTime(2026, 11, 7, 11, 0),
      ),
      myUserId: 'me',
      now: now,
    );
    expect(sent.subtitle, 'You: Hello there friend');
    expect(sent.timeLabel, '11:00');

    final failed = chatListPreviewFromRecord(
      _record(
        plaintext: 'Nope',
        senderId: 'me',
        createdAt: DateTime(2026, 11, 7, 11, 0),
        delivery: LocalMessageDelivery.failed,
      ),
      myUserId: 'me',
      now: now,
    );
    expect(failed.subtitle, startsWith('Couldn’t send'));
    expect(failed.subtitle, contains('You: Nope'));

    final incoming = chatListPreviewFromRecord(
      _record(
        plaintext: 'Hi',
        senderId: 'peer',
        createdAt: DateTime(2026, 11, 7, 11, 0),
        delivery: LocalMessageDelivery.received,
      ),
      myUserId: 'me',
      now: now,
    );
    expect(incoming.subtitle, 'Hi');
  });

  test('empty conversation preview has no timestamp', () {
    final empty = ChatListPreview(
      subtitle: 'No messages yet',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
    expect(empty.subtitle, 'No messages yet');
    expect(empty.timeLabel, isNull);
  });

  test('long plaintext is truncated for list preview', () {
    final long = 'a' * 120;
    final preview = chatListPreviewFromRecord(
      _record(
        plaintext: long,
        senderId: 'peer',
        createdAt: DateTime(2026, 11, 7, 11, 0),
        delivery: LocalMessageDelivery.received,
      ),
      myUserId: 'me',
      now: DateTime(2026, 11, 7, 12),
    );
    expect(preview.subtitle.length, lessThanOrEqualTo(72));
    expect(preview.subtitle.endsWith('…'), isTrue);
  });
}
