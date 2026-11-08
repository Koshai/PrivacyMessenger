import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chats/conversation_peer_index.dart';
import 'package:private_messenger/features/messaging/local_message_store.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('peer_privacy_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('peer index path is scoped by user and device database name', () {
    final alice = LocalMessageStore.databasePath(
      directory: temp.path,
      userId: 'alice',
      deviceId: 'dev-a',
    );
    final bob = LocalMessageStore.databasePath(
      directory: temp.path,
      userId: 'bob',
      deviceId: 'dev-b',
    );
    final alicePeers = ConversationPeerIndex.pathBesideDatabase(alice);
    final bobPeers = ConversationPeerIndex.pathBesideDatabase(bob);
    expect(alicePeers, isNot(bobPeers));
    expect(alicePeers, contains('alice'));
    expect(bobPeers, contains('bob'));
  });

  test('sidecar stores only opaque ids, never message plaintext', () async {
    final path = '${temp.path}/messages_alice_dev.peers.json';
    final index = ConversationPeerIndex(path: path);
    await index.bind(
      conversationId: 'conv-uuid-1',
      peerUserId: 'peer-uuid-2',
    );
    final raw = await File(path).readAsString();
    expect(raw.contains('peer-uuid-2'), isTrue);
    expect(raw.contains('conv-uuid-1'), isTrue);
    expect(raw.toLowerCase().contains('hello'), isFalse);
    expect(raw.contains('plaintext'), isFalse);
    expect(raw.contains('@'), isFalse);
  });

  test('corrupt sidecar fails closed without throwing', () async {
    final path = '${temp.path}/broken.peers.json';
    await File(path).writeAsString('{not-json');
    final index = ConversationPeerIndex(path: path);
    await index.load();
    expect(index.conversationIdForPeer('anyone'), isNull);
  });

  test('missing sidecar loads as empty', () async {
    final index = ConversationPeerIndex(
      path: '${temp.path}/missing.peers.json',
    );
    await index.load();
    expect(index.conversationIdForPeer('peer'), isNull);
  });
}
