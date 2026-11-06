import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/messaging/local_message_store.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('pm_history_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('round-trips a message and keeps plaintext out of sqlite', () async {
    const secret = 'pm-history-plaintext-7f3c9a';
    final storage = const FlutterSecureStorage();
    final path = _dbPath(tempDir, 'round-trip.db');
    final store = await _open(storage: storage, path: path);

    final saved = await store.insert(
      LocalMessageDraft(
        conversationId: 'conversation-1',
        senderId: 'sender-1',
        clientMessageId: 'client-1',
        envelopeId: 'envelope-1',
        conversationSeq: 4,
        createdAt: DateTime.utc(2026, 3, 1, 12),
        delivery: LocalMessageDelivery.received,
        plaintext: secret,
      ),
    );
    expect(saved.plaintext, secret);
    expect(saved.toString(), isNot(contains(secret)));

    final byClient = await store.lookupByClientMessageId(
      conversationId: 'conversation-1',
      clientMessageId: 'client-1',
    );
    final byEnvelope = await store.lookupByEnvelopeId('envelope-1');
    expect(byClient?.plaintext, secret);
    expect(byEnvelope?.senderId, 'sender-1');
    expect(byEnvelope?.conversationSeq, 4);
    expect(byEnvelope?.delivery, LocalMessageDelivery.received);

    final updated = await store.update(
      conversationId: 'conversation-1',
      clientMessageId: 'client-1',
      delivery: LocalMessageDelivery.sent,
      conversationSeq: 8,
    );
    expect(updated.plaintext, secret);
    expect(updated.delivery, LocalMessageDelivery.sent);
    expect(updated.conversationSeq, 8);
    expect(
      (await store.lookupByClientMessageId(
        conversationId: 'conversation-1',
        clientMessageId: 'client-1',
      ))?.conversationSeq,
      8,
    );

    await store.close();

    final bytes = await File(path).readAsBytes();
    expect(_containsAscii(bytes, secret), isFalse);
    final raw = await databaseFactoryFfi.openDatabase(path);
    final info = await raw.rawQuery('PRAGMA table_info(local_messages)');
    final columnNames = info.map((row) => row['name']).toSet();
    expect(columnNames, isNot(contains('plaintext')));
    final rows = await raw.query('local_messages');
    expect(rows, hasLength(1));
    for (final row in rows) {
      for (final value in row.values) {
        expect('$value', isNot(contains(secret)));
      }
    }
    final version = await raw.rawQuery('PRAGMA user_version');
    expect(version.single.values.single, LocalMessageStore.schemaVersion);
    final meta = await raw.query(
      'message_store_meta',
      where: 'meta_key = ?',
      whereArgs: ['schema_version'],
    );
    expect(meta.single['meta_value'], '${LocalMessageStore.schemaVersion}');
    await raw.close();
  });

  test(
    'duplicate client id and envelope id are idempotent or rejected',
    () async {
      final path = _dbPath(tempDir, 'dup.db');
      final store = await _open(path: path);
      final draft = _draft(plaintext: 'same-body', clientMessageId: 'client-1');
      final first = await store.insert(draft);
      final replay = await store.insert(draft);
      expect(replay.plaintext, first.plaintext);
      expect(replay.clientMessageId, first.clientMessageId);

      await expectLater(
        store.insert(
          _draft(plaintext: 'other-body', clientMessageId: 'client-1'),
        ),
        throwsA(isA<MessageHistoryConflictException>()),
      );
      expect(
        (await store.lookupByClientMessageId(
          conversationId: 'conversation-1',
          clientMessageId: 'client-1',
        ))?.plaintext,
        'same-body',
      );

      await store.insert(
        _draft(
          plaintext: 'second',
          clientMessageId: 'client-2',
          envelopeId: 'envelope-2',
        ),
      );
      await expectLater(
        store.insert(
          _draft(
            plaintext: 'third',
            clientMessageId: 'client-3',
            envelopeId: 'envelope-2',
          ),
        ),
        throwsA(isA<MessageHistoryConflictException>()),
      );
      expect(await store.lookupByEnvelopeId('envelope-2'), isNotNull);
      expect(
        (await store.lookupByClientMessageId(
          conversationId: 'conversation-1',
          clientMessageId: 'client-3',
        )),
        isNull,
      );

      await expectLater(
        store.update(
          conversationId: 'conversation-1',
          clientMessageId: 'client-1',
          envelopeId: 'envelope-2',
        ),
        throwsA(isA<MessageHistoryConflictException>()),
      );
      expect(
        (await store.lookupByClientMessageId(
          conversationId: 'conversation-1',
          clientMessageId: 'client-1',
        ))?.envelopeId,
        isNull,
      );
      await store.close();

      final raw = await databaseFactoryFfi.openDatabase(path);
      final count = Sqflite.firstIntValue(
        await raw.rawQuery('SELECT COUNT(*) FROM local_messages'),
      );
      expect(count, 2);
      await raw.close();
    },
  );

  test('lists a conversation by sequence, time, and client id', () async {
    final store = await _open(path: _dbPath(tempDir, 'order.db'));
    await store.insert(
      _draft(
        clientMessageId: 'a',
        conversationSeq: 2,
        createdAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
      ),
    );
    await store.insert(
      _draft(
        clientMessageId: 'b',
        conversationSeq: 1,
        createdAt: DateTime.utc(2026, 1, 1, 0, 0, 5),
      ),
    );
    await store.insert(
      _draft(
        clientMessageId: 'c',
        conversationSeq: null,
        createdAt: DateTime.utc(2026, 1, 1, 0, 0, 0),
      ),
    );
    await store.insert(
      _draft(
        clientMessageId: 'd',
        conversationSeq: 2,
        createdAt: DateTime.utc(2026, 1, 1, 0, 0, 3),
      ),
    );
    await store.insert(
      _draft(
        clientMessageId: 'other',
        conversationId: 'conversation-2',
        conversationSeq: 1,
        createdAt: DateTime.utc(2026, 1, 1, 0, 0, 0),
      ),
    );

    final listed = await store.listConversation('conversation-1');
    expect(listed.map((message) => message.clientMessageId), [
      'b',
      'a',
      'd',
      'c',
    ]);
    expect(
      (await store.listConversation('conversation-2')).single.clientMessageId,
      'other',
    );
    await store.close();
  });

  test('wrong key and modified metadata fail closed', () async {
    const secret = 'metadata-secret-body';
    final storage = const FlutterSecureStorage();
    final path = _dbPath(tempDir, 'auth.db');
    final store = await _open(storage: storage, path: path);
    await store.insert(
      _draft(
        plaintext: secret,
        envelopeId: 'envelope-1',
        clientMessageId: 'c1',
      ),
    );
    await store.close();

    final raw = await databaseFactoryFfi.openDatabase(path);
    await raw.update(
      'local_messages',
      {'sender_id': 'tampered-sender'},
      where: 'client_message_id = ?',
      whereArgs: ['c1'],
    );
    await raw.close();

    final reopened = await _open(storage: storage, path: path);
    final failure = expectLater(
      reopened.listConversation('conversation-1'),
      throwsA(
        isA<MessageHistoryCorruptException>().having(
          (error) => error.toString(),
          'toString',
          isNot(contains(secret)),
        ),
      ),
    );
    await failure;
    await reopened.close();

    final ciphertext = await databaseFactoryFfi.openDatabase(path);
    final rows = await ciphertext.query('local_messages');
    final blob = rows.single['ciphertext'];
    final flipped = Uint8List.fromList(
      blob is Uint8List ? blob : blob as List<int>,
    );
    flipped[flipped.length - 1] ^= 0x01;
    await ciphertext.update(
      'local_messages',
      {'sender_id': 'sender-1', 'ciphertext': flipped},
      where: 'client_message_id = ?',
      whereArgs: ['c1'],
    );
    await ciphertext.close();

    final afterFlip = await _open(storage: storage, path: path);
    await expectLater(
      afterFlip.lookupByClientMessageId(
        conversationId: 'conversation-1',
        clientMessageId: 'c1',
      ),
      throwsA(isA<MessageHistoryCorruptException>()),
    );
    await afterFlip.close();

    final keyName = LocalMessageStore.storageKeyFor('user-1', 'device-1');
    final original = await storage.read(key: keyName);
    await storage.write(
      key: keyName,
      value: base64Encode(Uint8List(32)..[0] = 7),
    );
    await expectLater(
      _open(storage: storage, path: path),
      throwsA(isA<MessageHistoryKeyLossException>()),
    );
    expect(await storage.read(key: keyName), isNot(original));
    expect(
      await storage.read(key: keyName),
      base64Encode(Uint8List(32)..[0] = 7),
    );

    await storage.write(key: keyName, value: original);
    final restored = await _open(storage: storage, path: path);
    await restored.close();
  });

  test(
    'reopen retains messages and a missing key does not regenerate',
    () async {
      const secret = 'survives-reopen';
      final storage = const FlutterSecureStorage();
      final path = _dbPath(tempDir, 'reopen.db');
      final keyName = LocalMessageStore.storageKeyFor('user-1', 'device-1');
      final first = await _open(storage: storage, path: path);
      await first.insert(_draft(plaintext: secret));
      await first.close();

      final second = await _open(storage: storage, path: path);
      expect(
        (await second.lookupByClientMessageId(
          conversationId: 'conversation-1',
          clientMessageId: 'client-1',
        ))?.plaintext,
        secret,
      );
      await second.close();

      final original = await storage.read(key: keyName);
      expect(original, isNotNull);
      await storage.delete(key: keyName);
      await expectLater(
        _open(storage: storage, path: path),
        throwsA(isA<MessageHistoryKeyLossException>()),
      );
      expect(await storage.read(key: keyName), isNull);
      expect(File(path).existsSync(), isTrue);

      await expectLater(
        _open(storage: storage, path: path),
        throwsA(isA<MessageHistoryKeyLossException>()),
      );
      expect(await storage.read(key: keyName), isNull);

      await storage.write(key: keyName, value: original);
      final restored = await _open(storage: storage, path: path);
      expect(
        (await restored.listConversation('conversation-1')).single.plaintext,
        secret,
      );
      await restored.close();

      final stripped = await databaseFactoryFfi.openDatabase(path);
      await stripped.delete(
        'message_store_meta',
        where: 'meta_key = ?',
        whereArgs: ['key_check'],
      );
      await stripped.close();
      await expectLater(
        _open(storage: storage, path: path),
        throwsA(isA<MessageHistoryKeyLossException>()),
      );
      expect(await storage.read(key: keyName), original);
      final stillStripped = await databaseFactoryFfi.openDatabase(path);
      final checks = await stillStripped.query(
        'message_store_meta',
        where: 'meta_key = ?',
        whereArgs: ['key_check'],
      );
      expect(checks, isEmpty);
      expect(
        Sqflite.firstIntValue(
          await stillStripped.rawQuery('SELECT COUNT(*) FROM local_messages'),
        ),
        1,
      );
      await stillStripped.close();
    },
  );

  test('malformed key material is left untouched', () async {
    final storage = const FlutterSecureStorage();
    final path = _dbPath(tempDir, 'malformed.db');
    final keyName = LocalMessageStore.storageKeyFor('user-1', 'device-1');
    final created = await _open(storage: storage, path: path);
    await created.close();
    await storage.write(key: keyName, value: 'not-a-key');

    await expectLater(
      _open(storage: storage, path: path),
      throwsA(isA<MessageHistoryKeyLossException>()),
    );
    expect(await storage.read(key: keyName), 'not-a-key');

    final emptyPath = _dbPath(tempDir, 'malformed-empty.db');
    final emptyName = LocalMessageStore.storageKeyFor('user-2', 'device-2');
    await storage.write(key: emptyName, value: '');
    await expectLater(
      _open(
        storage: storage,
        path: emptyPath,
        userId: 'user-2',
        deviceId: 'device-2',
      ),
      throwsA(isA<MessageHistoryKeyLossException>()),
    );
    expect(await storage.read(key: emptyName), '');
    expect(File(emptyPath).existsSync(), isFalse);
  });

  test('user and device stores cannot read each other', () async {
    final storage = const FlutterSecureStorage();
    final firstPath = _dbPath(tempDir, 'user-a.db');
    final secondPath = _dbPath(tempDir, 'user-b.db');
    final first = await _open(
      storage: storage,
      path: firstPath,
      userId: 'user-a',
      deviceId: 'device-a',
    );
    final second = await _open(
      storage: storage,
      path: secondPath,
      userId: 'user-b',
      deviceId: 'device-b',
    );
    await first.insert(_draft(plaintext: 'alpha-only'));
    await second.insert(_draft(plaintext: 'beta-only'));

    expect(
      (await first.listConversation('conversation-1')).single.plaintext,
      'alpha-only',
    );
    expect(
      (await second.listConversation('conversation-1')).single.plaintext,
      'beta-only',
    );
    expect(
      await storage.read(
        key: LocalMessageStore.storageKeyFor('user-a', 'device-a'),
      ),
      isNot(
        await storage.read(
          key: LocalMessageStore.storageKeyFor('user-b', 'device-b'),
        ),
      ),
    );
    await first.close();
    await second.close();

    final userBKey = await storage.read(
      key: LocalMessageStore.storageKeyFor('user-b', 'device-b'),
    );
    await expectLater(
      _open(
        storage: storage,
        path: firstPath,
        userId: 'user-b',
        deviceId: 'device-b',
      ),
      throwsA(isA<MessageHistoryKeyLossException>()),
    );
    expect(
      await storage.read(
        key: LocalMessageStore.storageKeyFor('user-b', 'device-b'),
      ),
      userBKey,
    );

    final raw = await databaseFactoryFfi.openDatabase(firstPath);
    final copy = Map<String, Object?>.from(
      (await raw.query('local_messages')).single,
    );
    copy.remove('id');
    copy['owner_user_id'] = 'user-b';
    copy['client_message_id'] = 'foreign-client';
    await raw.insert('local_messages', copy);
    await raw.close();

    final again = await _open(
      storage: storage,
      path: firstPath,
      userId: 'user-a',
      deviceId: 'device-a',
    );
    final visible = await again.listConversation('conversation-1');
    expect(visible, hasLength(1));
    expect(visible.single.plaintext, 'alpha-only');
    expect(visible.single.ownerUserId, 'user-a');
    await again.close();
  });

  test('schema migration keeps existing rows and unrelated tables', () async {
    const secret = 'migration-plaintext';
    final storage = const FlutterSecureStorage();
    final path = _dbPath(tempDir, 'migrate.db');
    final store = await _open(storage: storage, path: path);
    await store.insert(_draft(plaintext: secret));
    await store.close();

    final prepared = await databaseFactoryFfi.openDatabase(path);
    await prepared.execute('CREATE TABLE sentinel (note TEXT NOT NULL)');
    await prepared.insert('sentinel', {'note': 'keep-me'});
    await prepared.rawQuery('PRAGMA user_version = 0');
    await prepared.close();

    final migrated = await _open(storage: storage, path: path);
    expect(
      (await migrated.listConversation('conversation-1')).single.plaintext,
      secret,
    );
    await migrated.insert(
      _draft(plaintext: 'after-migration', clientMessageId: 'client-2'),
    );
    await migrated.close();

    final raw = await databaseFactoryFfi.openDatabase(path);
    final sentinel = await raw.query('sentinel');
    expect(sentinel.single['note'], 'keep-me');
    final count = Sqflite.firstIntValue(
      await raw.rawQuery('SELECT COUNT(*) FROM local_messages'),
    );
    expect(count, 2);
    final version = await raw.rawQuery('PRAGMA user_version');
    expect(version.single.values.single, LocalMessageStore.schemaVersion);
    await raw.rawQuery('PRAGMA user_version = 5');
    await raw.close();

    await expectLater(
      _open(storage: storage, path: path),
      throwsA(isA<MessageHistorySchemaException>()),
    );

    final preserved = await databaseFactoryFfi.openDatabase(path);
    expect((await preserved.query('sentinel')).single['note'], 'keep-me');
    expect(
      Sqflite.firstIntValue(
        await preserved.rawQuery('SELECT COUNT(*) FROM local_messages'),
      ),
      2,
    );
    final fileBytes = await File(path).readAsBytes();
    expect(_containsAscii(fileBytes, secret), isFalse);
    expect(_containsAscii(fileBytes, 'after-migration'), isFalse);
    await preserved.close();
  });

  test('a version 1 database gains mls phase without losing plaintext', () async {
    const secret = 'v1-plaintext-kept';
    final storage = const FlutterSecureStorage();
    final path = _dbPath(tempDir, 'v1.db');
    final created = await _open(storage: storage, path: path);
    await created.insert(_draft(plaintext: secret, envelopeId: 'env-v1'));
    await created.close();

    final prepared = await databaseFactoryFfi.openDatabase(path);
    await prepared.execute('''
      CREATE TABLE local_messages_v1 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_user_id TEXT NOT NULL,
        owner_device_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        client_message_id TEXT NOT NULL,
        envelope_id TEXT,
        conversation_seq INTEGER,
        created_at TEXT NOT NULL,
        delivery TEXT NOT NULL,
        nonce BLOB NOT NULL,
        mac BLOB NOT NULL,
        ciphertext BLOB NOT NULL
      )
    ''');
    await prepared.execute('''
      INSERT INTO local_messages_v1 (
        id, owner_user_id, owner_device_id, conversation_id, sender_id,
        client_message_id, envelope_id, conversation_seq, created_at,
        delivery, nonce, mac, ciphertext
      )
      SELECT
        id, owner_user_id, owner_device_id, conversation_id, sender_id,
        client_message_id, envelope_id, conversation_seq, created_at,
        delivery, nonce, mac, ciphertext
      FROM local_messages
    ''');
    await prepared.execute('DROP TABLE local_messages');
    await prepared.execute(
      'ALTER TABLE local_messages_v1 RENAME TO local_messages',
    );
    await prepared.execute('''
      CREATE UNIQUE INDEX local_messages_client_uid
      ON local_messages (
        owner_user_id, owner_device_id, conversation_id, client_message_id
      )
    ''');
    await prepared.execute('''
      CREATE UNIQUE INDEX local_messages_envelope_uid
      ON local_messages (owner_user_id, owner_device_id, envelope_id)
      WHERE envelope_id IS NOT NULL
    ''');
    await prepared.rawUpdate(
      'UPDATE message_store_meta SET meta_value = ? WHERE meta_key = ?',
      ['1', 'schema_version'],
    );
    await prepared.rawQuery('PRAGMA user_version = 1');
    await prepared.close();

    final migrated = await _open(storage: storage, path: path);
    final legacy = (await migrated.listConversation('conversation-1')).single;
    expect(legacy.plaintext, secret);
    expect(legacy.mlsPhase, isNull);
    expect(legacy.delivery, LocalMessageDelivery.sending);
    final committed = await migrated.markInboundState(
      conversationId: 'conversation-1',
      clientMessageId: 'client-1',
      mlsPhase: LocalMlsPhase.committed,
      delivery: LocalMessageDelivery.received,
    );
    expect(committed.plaintext, secret);
    expect(committed.mlsPhase, LocalMlsPhase.committed);
    expect(committed.delivery, LocalMessageDelivery.received);
    await migrated.close();

    final reopened = await _open(storage: storage, path: path);
    final again = (await reopened.listConversation('conversation-1')).single;
    expect(again.plaintext, secret);
    expect(again.mlsPhase, LocalMlsPhase.committed);
    await reopened.close();

    final tampered = await databaseFactoryFfi.openDatabase(path);
    await tampered.rawUpdate(
      'UPDATE local_messages SET mls_phase = ?',
      ['not-a-phase'],
    );
    await tampered.close();
    final rejected = await _open(storage: storage, path: path);
    await expectLater(
      rejected.listConversation('conversation-1'),
      throwsA(isA<MessageHistoryCorruptException>()),
    );
    await rejected.close();
  });

  test('malformed metadata fails closed and deletion is scoped', () async {
    const secret = 'delete-me-secret';
    final path = _dbPath(tempDir, 'delete.db');
    final store = await _open(path: path);
    await store.insert(_draft(plaintext: secret, clientMessageId: 'keep'));
    await store.insert(
      _draft(
        plaintext: 'other',
        clientMessageId: 'drop',
        conversationId: 'conversation-1',
      ),
    );
    await store.insert(
      _draft(
        plaintext: 'elsewhere',
        clientMessageId: 'away',
        conversationId: 'conversation-2',
      ),
    );
    await store.close();

    final raw = await databaseFactoryFfi.openDatabase(path);
    await raw.update(
      'local_messages',
      {'delivery': 'not-a-state'},
      where: 'client_message_id = ?',
      whereArgs: ['keep'],
    );
    await raw.close();

    final broken = await _open(path: path);
    await expectLater(
      broken.lookupByClientMessageId(
        conversationId: 'conversation-1',
        clientMessageId: 'keep',
      ),
      throwsA(
        isA<MessageHistoryCorruptException>().having(
          (error) => error.toString(),
          'toString',
          isNot(contains(secret)),
        ),
      ),
    );
    await expectLater(
      broken.listConversation('conversation-1'),
      throwsA(isA<MessageHistoryCorruptException>()),
    );
    await broken.deleteMessage(
      conversationId: 'conversation-1',
      clientMessageId: 'drop',
    );
    await broken.deleteConversation('conversation-2');
    expect(
      await broken.lookupByClientMessageId(
        conversationId: 'conversation-2',
        clientMessageId: 'away',
      ),
      isNull,
    );
    await broken.deleteMessage(
      conversationId: 'conversation-1',
      clientMessageId: 'keep',
    );
    expect(await broken.listConversation('conversation-1'), isEmpty);
    await broken.deleteAll();
    await broken.close();

    final left = await databaseFactoryFfi.openDatabase(path);
    final count = Sqflite.firstIntValue(
      await left.rawQuery('SELECT COUNT(*) FROM local_messages'),
    );
    expect(count, 0);
    expect(File(path).existsSync(), isTrue);
    await left.close();
  });
}

Future<LocalMessageStore> _open({
  required String path,
  FlutterSecureStorage? storage,
  String userId = 'user-1',
  String deviceId = 'device-1',
}) {
  return LocalMessageStore.open(
    userId: userId,
    deviceId: deviceId,
    dbPath: path,
    storage: storage,
    factory: databaseFactoryFfi,
  );
}

String _dbPath(Directory dir, String name) =>
    '${dir.path}${Platform.pathSeparator}$name';

LocalMessageDraft _draft({
  String plaintext = 'body',
  String conversationId = 'conversation-1',
  String senderId = 'sender-1',
  String clientMessageId = 'client-1',
  String? envelopeId,
  int? conversationSeq = 1,
  DateTime? createdAt,
  LocalMessageDelivery delivery = LocalMessageDelivery.sending,
}) {
  return LocalMessageDraft(
    conversationId: conversationId,
    senderId: senderId,
    clientMessageId: clientMessageId,
    envelopeId: envelopeId,
    conversationSeq: conversationSeq,
    createdAt: createdAt ?? DateTime.utc(2026, 2, 2, 2),
    delivery: delivery,
    plaintext: plaintext,
  );
}

bool _containsAscii(List<int> haystack, String needle) {
  final bytes = utf8.encode(needle);
  if (bytes.isEmpty || haystack.length < bytes.length) return false;
  for (var i = 0; i <= haystack.length - bytes.length; i++) {
    var match = true;
    for (var j = 0; j < bytes.length; j++) {
      if (haystack[i + j] != bytes[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
