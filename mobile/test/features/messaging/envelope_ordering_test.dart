import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/crypto/protocol_messages.dart';
import 'package:private_messenger/features/messaging/models/envelope.dart';

void main() {
  test('durable conversation_seq beats wall-clock for processing order', () {
    final lateWelcome = MessageEnvelope(
      id: '1',
      conversationId: 'c',
      senderId: 'a',
      clientMessageId: 'w',
      ciphertext: const [1],
      contentType: MlsContentTypes.welcome,
      createdAt: DateTime.utc(2026, 1, 2),
      conversationSeq: 1,
    );
    final earlyApp = MessageEnvelope(
      id: '2',
      conversationId: 'c',
      senderId: 'a',
      clientMessageId: 'm',
      ciphertext: const [2],
      contentType: MlsContentTypes.application,
      createdAt: DateTime.utc(2026, 1, 1),
      conversationSeq: 2,
    );
    final list = [earlyApp, lateWelcome]..sort(compareEnvelopesForProcessing);
    expect(list.first.contentType, MlsContentTypes.welcome);
    expect(list.last.contentType, MlsContentTypes.application);
  });

  test('same seq falls back to protocol rank (welcome before commit)', () {
    final commit = MessageEnvelope(
      id: 'c',
      conversationId: 'g',
      senderId: 'a',
      clientMessageId: 'commit',
      ciphertext: const [1],
      contentType: MlsContentTypes.commit,
      createdAt: DateTime.utc(2026, 1, 1),
      conversationSeq: 5,
    );
    final welcome = MessageEnvelope(
      id: 'w',
      conversationId: 'g',
      senderId: 'a',
      clientMessageId: 'welcome',
      ciphertext: const [2],
      contentType: MlsContentTypes.welcome,
      createdAt: DateTime.utc(2026, 1, 1),
      conversationSeq: 5,
    );
    final list = [commit, welcome]..sort(compareEnvelopesForProcessing);
    expect(list.first.id, 'w');
  });
}
