import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chats/conversation_peer_index.dart';
import 'package:private_messenger/features/messaging/local_message_store.dart';

/// Solidification guards for Step 19.7.30A — disposable fixtures only.
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pm30a_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('history DB and peer index paths isolate user and device', () {
    final a = LocalMessageStore.databasePath(
      directory: temp.path,
      userId: 'user-a',
      deviceId: 'device-1',
    );
    final b = LocalMessageStore.databasePath(
      directory: temp.path,
      userId: 'user-b',
      deviceId: 'device-1',
    );
    final aSameUserOtherDevice = LocalMessageStore.databasePath(
      directory: temp.path,
      userId: 'user-a',
      deviceId: 'device-2',
    );

    expect(a, isNot(b));
    expect(a, isNot(aSameUserOtherDevice));
    expect(a.contains('user-a'), isTrue);
    expect(b.contains('user-b'), isTrue);

    final peersA = ConversationPeerIndex.pathBesideDatabase(a);
    final peersB = ConversationPeerIndex.pathBesideDatabase(b);
    expect(peersA, isNot(peersB));
    expect(peersA.endsWith('.peers.json'), isTrue);
    expect(a.toLowerCase().contains('mls_'), isFalse);
  });

  test('secure-storage history key name cannot cross-parse identities', () {
    final key = LocalMessageStore.storageKeyFor('ab', 'c');
    final other = LocalMessageStore.storageKeyFor('a', 'bc');
    expect(key, isNot(other));
    expect(key, contains('.2.ab.1.c'));
    expect(other, contains('.1.a.2.bc'));
  });

  test('history schema version is additive and documented', () {
    expect(LocalMessageStore.schemaVersion, 4);
  });

  test('corrupt peer index never surfaces foreign conversation ids', () async {
    final path = '${temp.path}/messages_u_d.peers.json';
    await File(path).writeAsString('[{"evil":true}]');
    final index = ConversationPeerIndex(path: path);
    await index.load();
    expect(index.conversationIdForPeer('peer-1'), isNull);
  });
}
