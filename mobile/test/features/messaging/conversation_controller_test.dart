import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/messaging/conversation_controller.dart';
import 'package:private_messenger/features/messaging/models/envelope.dart';

void main() {
  test('ChatMessageView copyWith updates delivery only after server accept', () {
    final msg = ChatMessageView(
      clientMessageId: 'c1',
      senderId: 'u1',
      plaintext: 'hello',
      createdAt: DateTime.utc(2026, 1, 1),
      delivery: ChatDeliveryState.sending,
      isMine: true,
    );
    final sent = msg.copyWith(
      delivery: ChatDeliveryState.sent,
      serverEnvelopeId: 'e1',
    );
    expect(sent.delivery, ChatDeliveryState.sent);
    expect(sent.serverEnvelopeId, 'e1');
    expect(sent.plaintext, 'hello');
  });

  test('MessageEnvelope parses opaque ciphertext without plaintext fields', () {
    final env = MessageEnvelope.fromJson({
      'id': '11111111-1111-1111-1111-111111111111',
      'conversation_id': '22222222-2222-2222-2222-222222222222',
      'sender_id': '33333333-3333-3333-3333-333333333333',
      'client_message_id': 'c1',
      'ciphertext_b64': '3q0=',
      'content_type': 'application/mls-message',
      'created_at': '2026-01-01T00:00:00.000Z',
    });
    expect(env.ciphertext, [0xde, 0xad]);
    expect(env.contentType, 'application/mls-message');
  });

  test('acknowledged handshake history is not selected for ingest', () {
    final welcome = _env('w', 1, 'application/mls-welcome');
    final commit = _env('c', 2, 'application/mls-commit');
    final proposal = _env('p', 3, 'application/mls-proposal');
    final old = _env('a', 4, 'application/mls-message');
    final pendingApp = _env('b', 5, 'application/mls-message');

    final selected = selectEnvelopesForIngest(
      history: [pendingApp, old, proposal, commit, welcome],
      pending: [welcome, pendingApp],
    );

    expect(selected.map((e) => e.id), ['b', 'a', 'w']);
  });

  test('reopening without pending handshake does not select Welcome or Commit', () {
    final selected = selectEnvelopesForIngest(
      history: [
        _env('c', 2, 'application/mls-commit'),
        _env('w', 1, 'application/mls-welcome'),
        _env('a', 3, 'application/mls-message'),
      ],
      pending: const [],
    );
    expect(selected.map((e) => e.id), ['a']);
  });
}

MessageEnvelope _env(String id, int seq, String type) {
  return MessageEnvelope(
    id: id,
    conversationId: '44444444-4444-4444-8444-444444444444',
    senderId: '33333333-3333-4333-8333-333333333333',
    clientMessageId: 'client-$id',
    ciphertext: const [1],
    contentType: type,
    createdAt: DateTime.utc(2026, 1, seq),
    conversationSeq: seq,
  );
}
