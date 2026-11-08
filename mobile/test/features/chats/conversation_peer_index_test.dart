import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chats/conversation_peer_index.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('peer_index_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('pathBesideDatabase swaps .db suffix', () {
    expect(
      ConversationPeerIndex.pathBesideDatabase('/x/messages_u_d.db'),
      '/x/messages_u_d.peers.json',
    );
  });

  test('bind persists and reloads peer conversation ids only', () async {
    final path = '${temp.path}/index.peers.json';
    final index = ConversationPeerIndex(path: path);
    await index.bind(conversationId: 'conv-1', peerUserId: 'peer-a');
    expect(index.conversationIdForPeer('peer-a'), 'conv-1');

    final reloaded = ConversationPeerIndex(path: path);
    await reloaded.load();
    expect(reloaded.conversationIdForPeer('peer-a'), 'conv-1');
    expect(reloaded.conversationIdForPeer('missing'), isNull);

    final raw = await File(path).readAsString();
    expect(raw.contains('peer-a'), isTrue);
    expect(raw.contains('conv-1'), isTrue);
    expect(raw.toLowerCase().contains('password'), isFalse);
  });
}
