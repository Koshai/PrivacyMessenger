import 'package:flutter_test/flutter_test.dart';
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
}
