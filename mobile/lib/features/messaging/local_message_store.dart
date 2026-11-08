import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/crypto/secure_storage_factory.dart';

/// AES-GCM message history for one account on one device.
///
/// The database is a normal SQLite file. Plaintext is encrypted before it is
/// written and is never stored in a column. This file is not the OpenMLS
/// SQLCipher database; opening or migrating it does not touch MLS state.
///
/// The 256-bit key lives in [FlutterSecureStorage] (Android Keystore / iOS
/// Keychain). A missing key is created only when no history file exists yet.
/// A missing or malformed key is never replaced when a history file is present.
class LocalMessageStore implements InboundMessageHistory {
  LocalMessageStore._({
    required this.userId,
    required this.deviceId,
    required this.dbPath,
    required this._db,
    required this._key,
  });

  /// Current on-disk schema. Migrations may only add objects.
  static const schemaVersion = 4;

  static const _messagesTable = 'local_messages';
  static const _metaTable = 'message_store_meta';
  static const _schemaVersionKey = 'schema_version';
  static const _keyCheckKey = 'key_check';

  final String userId;
  final String deviceId;
  final String dbPath;

  final AesGcm _aes = AesGcm.with256bits();
  Database? _db;
  Uint8List? _key;
  Future<void> _queue = Future<void>.value();
  bool _closed = false;

  /// Opens or creates [dbPath] for this user and device.
  ///
  /// [factory] lets tests supply an in-process SQLite implementation. The
  /// production caller leaves it null so sqflite uses the device plugin.
  static Future<LocalMessageStore> open({
    required String userId,
    required String deviceId,
    required String dbPath,
    FlutterSecureStorage? storage,
    DatabaseFactory? factory,
  }) async {
    _validateOwner(userId: userId, deviceId: deviceId);
    if (dbPath.trim().isEmpty) {
      throw ArgumentError.value(dbPath, 'dbPath', 'database path is empty');
    }

    final secure = storage ?? createAppSecureStorage();
    final storageKey = storageKeyFor(userId, deviceId);
    final key = await _loadOrCreateKey(
      storage: secure,
      storageKey: storageKey,
      dbPath: dbPath,
    );

    await File(dbPath).parent.create(recursive: true);
    final opener = factory ?? databaseFactory;
    final db = await opener.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (database, version) async {
          await _migrate(database, 0, version);
        },
        onUpgrade: (database, oldVersion, newVersion) async {
          await _migrate(database, oldVersion, newVersion);
        },
        onDowngrade: (database, oldVersion, newVersion) async {
          throw const MessageHistorySchemaException();
        },
        onOpen: (database) async {
          await _verifyOrCreateKeyCheck(
            database: database,
            aes: AesGcm.with256bits(),
            key: key,
          );
        },
        singleInstance: true,
      ),
    );

    return LocalMessageStore._(
      userId: userId,
      deviceId: deviceId,
      dbPath: dbPath,
      db: db,
      key: key,
    );
  }

  /// Secure-storage name for this account and device.
  ///
  /// The user id and device id are length-prefixed so one cannot be parsed as
  /// part of the other.
  static String storageKeyFor(String userId, String deviceId) {
    _validateOwner(userId: userId, deviceId: deviceId);
    return 'message_history_key_v1.${userId.length}.$userId.'
        '${deviceId.length}.$deviceId';
  }

  /// Path of the history file for this account. It is never an MLS database.
  static String databasePath({
    required String directory,
    required String userId,
    required String deviceId,
  }) {
    _validateOwner(userId: userId, deviceId: deviceId);
    if (directory.trim().isEmpty) {
      throw ArgumentError('message history directory is empty');
    }
    for (final value in [userId, deviceId]) {
      if (value.contains('/') ||
          value.contains('\\') ||
          value.contains('\u0000')) {
        throw ArgumentError('message history path is invalid');
      }
    }
    final name = 'messages_${userId}_$deviceId.db';
    if (name.startsWith('mls_')) {
      throw ArgumentError('message history path is invalid');
    }
    return '$directory${Platform.pathSeparator}$name';
  }

  /// Inserts a message, or returns the existing row when every authenticated
  /// field and the plaintext match. A reused client id or envelope id with
  /// different contents is left unchanged and reported as a conflict.
  @override
  Future<LocalMessageRecord> insert(LocalMessageDraft draft) {
    return _enqueue(() async {
      final db = _requireDb();
      _validateDraft(draft);
      final createdAt = _canonicalTime(draft.createdAt);
      return db.transaction((txn) async {
        final byClient = await _rowByClient(
          txn,
          conversationId: draft.conversationId,
          clientMessageId: draft.clientMessageId,
        );
        if (byClient != null) {
          final existing = await _decryptRow(byClient);
          if (_samePayload(existing, draft, createdAt)) return existing;
          throw const MessageHistoryConflictException();
        }
        if (draft.envelopeId != null) {
          final byEnvelope = await _rowByEnvelope(txn, draft.envelopeId!);
          if (byEnvelope != null) {
            throw const MessageHistoryConflictException();
          }
        }
        final record = _recordFromDraft(draft, createdAt);
        try {
          final written = await _encryptedRow(record);
          if (record.hasPreparedOutbox) {
            written.addAll(await _outboxColumns(record));
          }
          await txn.insert(_messagesTable, written);
        } on DatabaseException catch (error) {
          if (error.isUniqueConstraintError()) {
            throw const MessageHistoryConflictException();
          }
          throw StateError('Message history write failed');
        }
        return record;
      });
    });
  }

  /// Updates delivery, MLS phase, the server envelope id, or the sequence.
  ///
  /// The plaintext is encrypted again because those fields are part of the
  /// authenticated metadata. The previous row is restored if the write fails.
  Future<LocalMessageRecord> update({
    required String conversationId,
    required String clientMessageId,
    LocalMessageDelivery? delivery,
    Object? envelopeId = _unchanged,
    Object? conversationSeq = _unchanged,
    Object? mlsPhase = _unchanged,
    Object? preparedCiphertext = _unchanged,
    Object? mlsGroupIdHex = _unchanged,
    Object? outboxRecipientId = _unchanged,
    Object? outboxContentType = _unchanged,
  }) {
    return _enqueue(() async {
      final db = _requireDb();
      _validateIdentity(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
      );
      return db.transaction((txn) async {
        final row = await _rowByClient(
          txn,
          conversationId: conversationId,
          clientMessageId: clientMessageId,
        );
        if (row == null) throw const MessageHistoryNotFoundException();
        final current = await _decryptRow(row);
        final nextEnvelope = envelopeId == _unchanged
            ? current.envelopeId
            : _optionalText(envelopeId, 'envelopeId');
        final nextSeq = conversationSeq == _unchanged
            ? current.conversationSeq
            : _optionalSeq(conversationSeq);
        final nextPhase = mlsPhase == _unchanged
            ? current.mlsPhase
            : _optionalPhase(mlsPhase);
        final nextWire = preparedCiphertext == _unchanged
            ? current.preparedCiphertext
            : _optionalWire(preparedCiphertext);
        final nextGroup = mlsGroupIdHex == _unchanged
            ? current.mlsGroupIdHex
            : _optionalText(mlsGroupIdHex, 'mlsGroupIdHex');
        final nextRecipient = outboxRecipientId == _unchanged
            ? current.outboxRecipientId
            : _optionalText(outboxRecipientId, 'outboxRecipientId');
        final nextContentType = outboxContentType == _unchanged
            ? current.outboxContentType
            : _optionalText(outboxContentType, 'outboxContentType');
        if (nextWire != null &&
            (nextGroup == null ||
                nextGroup.isEmpty ||
                nextRecipient == null ||
                nextRecipient.isEmpty ||
                nextContentType == null ||
                nextContentType.isEmpty)) {
          throw ArgumentError(
            'mlsGroupIdHex, outboxRecipientId, and outboxContentType are '
            'required when prepared ciphertext is set',
          );
        }
        if (nextEnvelope != null) {
          final occupied = await _rowByEnvelope(txn, nextEnvelope);
          final occupiedClient = occupied?['client_message_id'];
          if (occupied != null &&
              (occupied['conversation_id'] != conversationId ||
                  occupiedClient != clientMessageId)) {
            throw const MessageHistoryConflictException();
          }
        }
        final updated = LocalMessageRecord(
          ownerUserId: userId,
          ownerDeviceId: deviceId,
          conversationId: current.conversationId,
          senderId: current.senderId,
          clientMessageId: current.clientMessageId,
          envelopeId: nextEnvelope,
          conversationSeq: nextSeq,
          createdAtRaw: current.createdAtRaw,
          delivery: delivery ?? current.delivery,
          mlsPhase: nextPhase,
          plaintext: current.plaintext,
          preparedCiphertext: nextWire,
          mlsGroupIdHex: nextWire == null ? null : nextGroup,
          outboxRecipientId: nextWire == null ? null : nextRecipient,
          outboxContentType: nextWire == null ? null : nextContentType,
        );
        final written = await _encryptedRow(updated);
        if (preparedCiphertext != _unchanged ||
            mlsGroupIdHex != _unchanged ||
            outboxRecipientId != _unchanged ||
            outboxContentType != _unchanged) {
          written.addAll(await _outboxColumns(updated));
        }
        int count;
        try {
          count = await txn.update(
            _messagesTable,
            written,
            where:
                'owner_user_id = ? AND owner_device_id = ? AND '
                'conversation_id = ? AND client_message_id = ?',
            whereArgs: [userId, deviceId, conversationId, clientMessageId],
          );
        } on DatabaseException catch (error) {
          if (error.isUniqueConstraintError()) {
            throw const MessageHistoryConflictException();
          }
          throw StateError('Message history write failed');
        }
        if (count != 1) throw const MessageHistoryCorruptException();
        return updated;
      });
    });
  }

  @override
  Future<LocalMessageRecord> markInboundState({
    required String conversationId,
    required String clientMessageId,
    LocalMlsPhase? mlsPhase,
    LocalMessageDelivery? delivery,
    Object? envelopeId = keepHistoryField,
    Object? conversationSeq = keepHistoryField,
    Object? preparedCiphertext = keepHistoryField,
    Object? mlsGroupIdHex = keepHistoryField,
    Object? outboxRecipientId = keepHistoryField,
    Object? outboxContentType = keepHistoryField,
  }) {
    return update(
      conversationId: conversationId,
      clientMessageId: clientMessageId,
      delivery: delivery,
      mlsPhase: mlsPhase ?? _unchanged,
      envelopeId:
          identical(envelopeId, keepHistoryField) ? _unchanged : envelopeId,
      conversationSeq: identical(conversationSeq, keepHistoryField)
          ? _unchanged
          : conversationSeq,
      preparedCiphertext: identical(preparedCiphertext, keepHistoryField)
          ? _unchanged
          : preparedCiphertext,
      mlsGroupIdHex: identical(mlsGroupIdHex, keepHistoryField)
          ? _unchanged
          : mlsGroupIdHex,
      outboxRecipientId: identical(outboxRecipientId, keepHistoryField)
          ? _unchanged
          : outboxRecipientId,
      outboxContentType: identical(outboxContentType, keepHistoryField)
          ? _unchanged
          : outboxContentType,
    );
  }

  @override
  Future<LocalMessageRecord?> lookupByClientMessageId({
    required String conversationId,
    required String clientMessageId,
  }) {
    return _enqueue(() async {
      _validateIdentity(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
      );
      final row = await _rowByClient(
        _requireDb(),
        conversationId: conversationId,
        clientMessageId: clientMessageId,
      );
      if (row == null) return null;
      return _decryptRow(row);
    });
  }

  @override
  Future<LocalMessageRecord?> lookupByEnvelopeId(String envelopeId) {
    return _enqueue(() async {
      final normalized = _optionalText(envelopeId, 'envelopeId');
      if (normalized == null) {
        throw ArgumentError.value(
          envelopeId,
          'envelopeId',
          'envelope id is empty',
        );
      }
      final row = await _rowByEnvelope(_requireDb(), normalized);
      if (row == null) return null;
      return _decryptRow(row);
    });
  }

  /// Messages in [conversationId], sequenced rows first, then unsequenced rows.
  ///
  /// Ties break by canonical timestamp and then client message id.
  @override
  Future<List<LocalMessageRecord>> listConversation(String conversationId) {
    return _enqueue(() async {
      if (conversationId.trim().isEmpty) {
        throw ArgumentError.value(
          conversationId,
          'conversationId',
          'conversation id is empty',
        );
      }
      final rows = await _requireDb().query(
        _messagesTable,
        where:
            'owner_user_id = ? AND owner_device_id = ? AND conversation_id = ?',
        whereArgs: [userId, deviceId, conversationId],
        orderBy:
            'CASE WHEN conversation_seq IS NULL THEN 1 ELSE 0 END, '
            'conversation_seq, created_at, client_message_id',
      );
      final records = <LocalMessageRecord>[];
      for (final row in rows) {
        records.add(await _decryptRow(row));
      }
      return records;
    });
  }

  /// Newest decrypted row in [conversationId], or null when empty / unknown.
  ///
  /// Prefers the highest [conversationSeq], then latest [createdAt].
  Future<LocalMessageRecord?> latestInConversation(String conversationId) {
    return _enqueue(() async {
      if (conversationId.trim().isEmpty) {
        throw ArgumentError.value(
          conversationId,
          'conversationId',
          'conversation id is empty',
        );
      }
      final rows = await _requireDb().query(
        _messagesTable,
        where:
            'owner_user_id = ? AND owner_device_id = ? AND conversation_id = ?',
        whereArgs: [userId, deviceId, conversationId],
        orderBy:
            'CASE WHEN conversation_seq IS NULL THEN 1 ELSE 0 END, '
            'conversation_seq DESC, created_at DESC, client_message_id DESC',
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return _decryptRow(rows.first);
    });
  }

  Future<void> deleteMessage({
    required String conversationId,
    required String clientMessageId,
  }) {
    return _enqueue(() async {
      _validateIdentity(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
      );
      await _requireDb().delete(
        _messagesTable,
        where:
            'owner_user_id = ? AND owner_device_id = ? AND '
            'conversation_id = ? AND client_message_id = ?',
        whereArgs: [userId, deviceId, conversationId, clientMessageId],
      );
    });
  }

  Future<void> deleteConversation(String conversationId) {
    return _enqueue(() async {
      if (conversationId.trim().isEmpty) {
        throw ArgumentError.value(
          conversationId,
          'conversationId',
          'conversation id is empty',
        );
      }
      await _requireDb().delete(
        _messagesTable,
        where:
            'owner_user_id = ? AND owner_device_id = ? AND conversation_id = ?',
        whereArgs: [userId, deviceId, conversationId],
      );
    });
  }

  /// Deletes every message owned by this user and device. The key and the
  /// database file stay in place so a later open does not mint a new key.
  Future<void> deleteAll() {
    return _enqueue(() async {
      await _requireDb().delete(
        _messagesTable,
        where: 'owner_user_id = ? AND owner_device_id = ?',
        whereArgs: [userId, deviceId],
      );
    });
  }

  Future<void> close() {
    return _enqueue(() async {
      if (_closed) return;
      _closed = true;
      final db = _db;
      _db = null;
      _key = null;
      await db?.close();
    }, allowClosed: true);
  }

  static void _validateOwner({
    required String userId,
    required String deviceId,
  }) {
    if (userId.isEmpty) {
      throw ArgumentError.value(userId, 'userId', 'user id is empty');
    }
    if (deviceId.isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'device id is empty');
    }
  }

  static Future<Uint8List> _loadOrCreateKey({
    required FlutterSecureStorage storage,
    required String storageKey,
    required String dbPath,
  }) async {
    final existing = await _readKey(storage, storageKey);
    if (existing != null) return existing;

    final file = File(dbPath);
    if (await file.exists() && await file.length() > 0) {
      throw const MessageHistoryKeyLossException();
    }

    final created = await AesGcm.with256bits().newSecretKey();
    final bytes = Uint8List.fromList(await created.extractBytes());
    if (bytes.length != 32 || _isAllZero(bytes)) {
      throw const MessageHistoryKeyLossException();
    }
    await storage.write(key: storageKey, value: base64Encode(bytes));
    final stored = await _readKey(storage, storageKey);
    if (stored == null || !_constantEquals(stored, bytes)) {
      throw const MessageHistoryKeyLossException();
    }
    return bytes;
  }

  /// Returns the key, or null when the slot is empty.
  ///
  /// A present value that is not 32-byte base64 fails closed and is left as it
  /// was written.
  static Future<Uint8List?> _readKey(
    FlutterSecureStorage storage,
    String storageKey,
  ) async {
    final raw = await storage.read(key: storageKey);
    if (raw == null) return null;
    if (raw.isEmpty) throw const MessageHistoryKeyLossException();
    Uint8List bytes;
    try {
      bytes = base64Decode(raw);
    } on FormatException {
      throw const MessageHistoryKeyLossException();
    }
    if (bytes.length != 32) throw const MessageHistoryKeyLossException();
    return bytes;
  }

  static Future<void> _migrate(DatabaseExecutor db, int from, int to) async {
    if (from > to || to != schemaVersion) {
      throw const MessageHistorySchemaException();
    }
    if (from < 1) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_metaTable (
          meta_key TEXT PRIMARY KEY,
          meta_value TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_messagesTable (
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
      await db.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS local_messages_client_uid
        ON $_messagesTable (
          owner_user_id,
          owner_device_id,
          conversation_id,
          client_message_id
        )
      ''');
      await db.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS local_messages_envelope_uid
        ON $_messagesTable (owner_user_id, owner_device_id, envelope_id)
        WHERE envelope_id IS NOT NULL
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS local_messages_conversation_order
        ON $_messagesTable (
          owner_user_id,
          owner_device_id,
          conversation_id,
          conversation_seq,
          created_at
        )
      ''');
    }
    if (from < 2) {
      final columns = await db.rawQuery('PRAGMA table_info($_messagesTable)');
      final hasPhase = columns.any((row) => row['name'] == 'mls_phase');
      if (!hasPhase) {
        await db.execute(
          'ALTER TABLE $_messagesTable ADD COLUMN mls_phase TEXT',
        );
      }
    }
    if (from < 3) {
      final columns = await db.rawQuery('PRAGMA table_info($_messagesTable)');
      final names = {
        for (final row in columns) row['name'] as String,
      };
      if (!names.contains('outbox_nonce')) {
        await db.execute(
          'ALTER TABLE $_messagesTable ADD COLUMN outbox_nonce BLOB',
        );
      }
      if (!names.contains('outbox_mac')) {
        await db.execute(
          'ALTER TABLE $_messagesTable ADD COLUMN outbox_mac BLOB',
        );
      }
      if (!names.contains('outbox_ciphertext')) {
        await db.execute(
          'ALTER TABLE $_messagesTable ADD COLUMN outbox_ciphertext BLOB',
        );
      }
      if (!names.contains('mls_group_id_hex')) {
        await db.execute(
          'ALTER TABLE $_messagesTable ADD COLUMN mls_group_id_hex TEXT',
        );
      }
    }
    if (from < 4) {
      final columns = await db.rawQuery('PRAGMA table_info($_messagesTable)');
      final names = {
        for (final row in columns) row['name'] as String,
      };
      if (!names.contains('outbox_recipient_id')) {
        await db.execute(
          'ALTER TABLE $_messagesTable ADD COLUMN outbox_recipient_id TEXT',
        );
      }
      if (!names.contains('outbox_content_type')) {
        await db.execute(
          'ALTER TABLE $_messagesTable ADD COLUMN outbox_content_type TEXT',
        );
      }
    }
    await db.rawInsert(
      '''
      INSERT INTO $_metaTable (meta_key, meta_value)
      VALUES (?, ?)
      ON CONFLICT(meta_key) DO UPDATE SET meta_value = excluded.meta_value
      WHERE CAST($_metaTable.meta_value AS INTEGER)
        < CAST(excluded.meta_value AS INTEGER)
      ''',
      [_schemaVersionKey, '$schemaVersion'],
    );
  }

  static Future<void> _verifyOrCreateKeyCheck({
    required Database database,
    required AesGcm aes,
    required Uint8List key,
  }) async {
    final existing = await database.query(
      _metaTable,
      columns: ['meta_value'],
      where: 'meta_key = ?',
      whereArgs: [_keyCheckKey],
    );
    if (existing.isEmpty) {
      final count = Sqflite.firstIntValue(
        await database.rawQuery('SELECT COUNT(*) FROM $_messagesTable'),
      );
      if ((count ?? 0) > 0) {
        throw const MessageHistoryKeyLossException();
      }
      final packed = await _packCheck(aes, key);
      await database.insert(_metaTable, {
        'meta_key': _keyCheckKey,
        'meta_value': packed,
      });
      return;
    }
    final packed = existing.single['meta_value'];
    if (packed is! String) throw const MessageHistoryCorruptException();
    try {
      await _unpackCheck(aes, key, packed);
    } on MessageHistoryCorruptException {
      throw const MessageHistoryKeyLossException();
    }
  }

  static Future<String> _packCheck(AesGcm aes, Uint8List key) async {
    final box = await aes.encrypt(
      const [1],
      secretKey: SecretKey(key),
      aad: utf8.encode('message-history-key-check-v1'),
    );
    return '${base64Encode(box.nonce)}.${base64Encode(box.mac.bytes)}.'
        '${base64Encode(box.cipherText)}';
  }

  static Future<void> _unpackCheck(
    AesGcm aes,
    Uint8List key,
    String packed,
  ) async {
    final parts = packed.split('.');
    if (parts.length != 3 || parts.any((part) => part.isEmpty)) {
      throw const MessageHistoryCorruptException();
    }
    try {
      final clear = await aes.decrypt(
        SecretBox(
          base64Decode(parts[2]),
          nonce: base64Decode(parts[0]),
          mac: Mac(base64Decode(parts[1])),
        ),
        secretKey: SecretKey(key),
        aad: utf8.encode('message-history-key-check-v1'),
      );
      if (clear.length != 1 || clear.single != 1) {
        throw const MessageHistoryCorruptException();
      }
    } on MessageHistoryCorruptException {
      rethrow;
    } on FormatException {
      throw const MessageHistoryCorruptException();
    } catch (_) {
      throw const MessageHistoryCorruptException();
    }
  }

  Database _requireDb() {
    final db = _db;
    if (_closed || db == null || _key == null) {
      throw StateError('Message history store is closed');
    }
    return db;
  }

  Future<T> _enqueue<T>(
    Future<T> Function() action, {
    bool allowClosed = false,
  }) {
    final result = _queue.then((_) {
      if (_closed && !allowClosed) {
        throw StateError('Message history store is closed');
      }
      return action();
    });
    _queue = result.then((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, Object?>?> _rowByClient(
    DatabaseExecutor db, {
    required String conversationId,
    required String clientMessageId,
  }) async {
    final rows = await db.query(
      _messagesTable,
      where:
          'owner_user_id = ? AND owner_device_id = ? AND '
          'conversation_id = ? AND client_message_id = ?',
      whereArgs: [userId, deviceId, conversationId, clientMessageId],
      limit: 2,
    );
    if (rows.length > 1) throw const MessageHistoryCorruptException();
    if (rows.isEmpty) return null;
    return rows.single;
  }

  Future<Map<String, Object?>?> _rowByEnvelope(
    DatabaseExecutor db,
    String envelopeId,
  ) async {
    final rows = await db.query(
      _messagesTable,
      where: 'owner_user_id = ? AND owner_device_id = ? AND envelope_id = ?',
      whereArgs: [userId, deviceId, envelopeId],
      limit: 2,
    );
    if (rows.length > 1) throw const MessageHistoryCorruptException();
    if (rows.isEmpty) return null;
    return rows.single;
  }

  LocalMessageRecord _recordFromDraft(
    LocalMessageDraft draft,
    String createdAt,
  ) {
    return LocalMessageRecord(
      ownerUserId: userId,
      ownerDeviceId: deviceId,
      conversationId: draft.conversationId,
      senderId: draft.senderId,
      clientMessageId: draft.clientMessageId,
      envelopeId: draft.envelopeId,
      conversationSeq: draft.conversationSeq,
      createdAtRaw: createdAt,
      delivery: draft.delivery,
      mlsPhase: draft.mlsPhase,
      plaintext: draft.plaintext,
      preparedCiphertext: draft.preparedCiphertext,
      mlsGroupIdHex: draft.mlsGroupIdHex,
      outboxRecipientId: draft.outboxRecipientId,
      outboxContentType: draft.outboxContentType,
    );
  }

  bool _samePayload(
    LocalMessageRecord existing,
    LocalMessageDraft draft,
    String createdAt,
  ) {
    return existing.senderId == draft.senderId &&
        existing.envelopeId == draft.envelopeId &&
        existing.conversationSeq == draft.conversationSeq &&
        existing.createdAtRaw == createdAt &&
        existing.delivery == draft.delivery &&
        existing.mlsPhase == draft.mlsPhase &&
        existing.plaintext == draft.plaintext;
  }

  Future<Map<String, Object?>> _encryptedRow(LocalMessageRecord record) async {
    final box = await _aes.encrypt(
      utf8.encode(record.plaintext),
      secretKey: SecretKey(_requireKey()),
      aad: _associatedData(record),
    );
    return {
      'owner_user_id': record.ownerUserId,
      'owner_device_id': record.ownerDeviceId,
      'conversation_id': record.conversationId,
      'sender_id': record.senderId,
      'client_message_id': record.clientMessageId,
      'envelope_id': record.envelopeId,
      'conversation_seq': record.conversationSeq,
      'created_at': record.createdAtRaw,
      'delivery': record.delivery.name,
      'mls_phase': record.mlsPhase?.name,
      'nonce': Uint8List.fromList(box.nonce),
      'mac': Uint8List.fromList(box.mac.bytes),
      'ciphertext': Uint8List.fromList(box.cipherText),
    };
  }

  /// Encrypts MLS wire bytes separately from plaintext history.
  ///
  /// Outbox columns are omitted from plaintext updates so a delivery change
  /// does not rewrite ciphertext. Clearing uses explicit null columns.
  Future<Map<String, Object?>> _outboxColumns(LocalMessageRecord record) async {
    final wire = record.preparedCiphertext;
    if (wire == null || wire.isEmpty) {
      return {
        'outbox_nonce': null,
        'outbox_mac': null,
        'outbox_ciphertext': null,
        'mls_group_id_hex': null,
        'outbox_recipient_id': null,
        'outbox_content_type': null,
      };
    }
    final group = record.mlsGroupIdHex;
    final recipient = record.outboxRecipientId;
    final contentType = record.outboxContentType;
    if (group == null ||
        group.isEmpty ||
        recipient == null ||
        recipient.isEmpty ||
        contentType == null ||
        contentType.isEmpty) {
      throw ArgumentError(
        'mlsGroupIdHex, outboxRecipientId, and outboxContentType are required '
        'for outbox persistence',
      );
    }
    final box = await _aes.encrypt(
      wire,
      secretKey: SecretKey(_requireKey()),
      aad: _outboxAssociatedData(
        conversationId: record.conversationId,
        clientMessageId: record.clientMessageId,
        senderId: record.senderId,
        recipientId: recipient,
        mlsGroupIdHex: group,
        contentType: contentType,
      ),
    );
    return {
      'outbox_nonce': Uint8List.fromList(box.nonce),
      'outbox_mac': Uint8List.fromList(box.mac.bytes),
      'outbox_ciphertext': Uint8List.fromList(box.cipherText),
      'mls_group_id_hex': group,
      'outbox_recipient_id': recipient,
      'outbox_content_type': contentType,
    };
  }

  Future<LocalMessageRecord> _decryptRow(Map<String, Object?> row) async {
    final record = _readMetadata(row);
    final nonce = _blob(row['nonce']);
    final mac = _blob(row['mac']);
    final ciphertext = _blob(row['ciphertext']);
    if (nonce.isEmpty || mac.isEmpty) {
      throw const MessageHistoryCorruptException();
    }
    List<int> clear;
    try {
      clear = await _aes.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(_requireKey()),
        aad: _associatedData(record),
      );
    } catch (_) {
      throw const MessageHistoryCorruptException();
    }
    final String plaintext;
    try {
      plaintext = utf8.decode(clear);
    } on FormatException {
      throw const MessageHistoryCorruptException();
    }
    final outbox = await _decryptOutbox(row, record);
    return record._withPlaintext(plaintext)._withOutbox(
      preparedCiphertext: outbox.wire,
      mlsGroupIdHex: outbox.groupId,
      outboxRecipientId: outbox.recipientId,
      outboxContentType: outbox.contentType,
    );
  }

  Future<
      ({
        List<int>? wire,
        String? groupId,
        String? recipientId,
        String? contentType,
      })> _decryptOutbox(
    Map<String, Object?> row,
    LocalMessageRecord record,
  ) async {
    final nonceRaw = row['outbox_nonce'];
    final macRaw = row['outbox_mac'];
    final cipherRaw = row['outbox_ciphertext'];
    final groupRaw = row['mls_group_id_hex'];
    final recipientRaw = row['outbox_recipient_id'];
    final contentTypeRaw = row['outbox_content_type'];
    final anyPresent = nonceRaw != null ||
        macRaw != null ||
        cipherRaw != null ||
        groupRaw != null ||
        recipientRaw != null ||
        contentTypeRaw != null;
    if (!anyPresent) {
      return (
        wire: null,
        groupId: null,
        recipientId: null,
        contentType: null,
      );
    }
    if (nonceRaw == null ||
        macRaw == null ||
        cipherRaw == null ||
        groupRaw is! String ||
        groupRaw.isEmpty ||
        recipientRaw is! String ||
        recipientRaw.isEmpty ||
        contentTypeRaw is! String ||
        contentTypeRaw.isEmpty) {
      throw const MessageHistoryCorruptException();
    }
    final nonce = _blob(nonceRaw);
    final mac = _blob(macRaw);
    final ciphertext = _blob(cipherRaw);
    if (nonce.isEmpty || mac.isEmpty || ciphertext.isEmpty) {
      throw const MessageHistoryCorruptException();
    }
    try {
      final wire = await _aes.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(_requireKey()),
        aad: _outboxAssociatedData(
          conversationId: record.conversationId,
          clientMessageId: record.clientMessageId,
          senderId: record.senderId,
          recipientId: recipientRaw,
          mlsGroupIdHex: groupRaw,
          contentType: contentTypeRaw,
        ),
      );
      if (wire.isEmpty) throw const MessageHistoryCorruptException();
      return (
        wire: List<int>.from(wire),
        groupId: groupRaw,
        recipientId: recipientRaw,
        contentType: contentTypeRaw,
      );
    } catch (_) {
      throw const MessageHistoryCorruptException();
    }
  }

  LocalMessageRecord _readMetadata(Map<String, Object?> row) {
    final ownerUserId = _text(row['owner_user_id']);
    final ownerDeviceId = _text(row['owner_device_id']);
    if (ownerUserId != userId || ownerDeviceId != deviceId) {
      throw const MessageHistoryCorruptException();
    }
    final createdAtRaw = _text(row['created_at']);
    if (DateTime.tryParse(createdAtRaw) == null) {
      throw const MessageHistoryCorruptException();
    }
    return LocalMessageRecord(
      ownerUserId: ownerUserId,
      ownerDeviceId: ownerDeviceId,
      conversationId: _text(row['conversation_id']),
      senderId: _text(row['sender_id']),
      clientMessageId: _text(row['client_message_id']),
      envelopeId: _nullableText(row['envelope_id']),
      conversationSeq: _nullableSeq(row['conversation_seq']),
      createdAtRaw: createdAtRaw,
      delivery: _delivery(row['delivery']),
      mlsPhase: _phase(row['mls_phase']),
      plaintext: '',
    );
  }

  Uint8List _requireKey() {
    final key = _key;
    if (key == null || key.length != 32) {
      throw const MessageHistoryKeyLossException();
    }
    return key;
  }

  static Uint8List _associatedData(LocalMessageRecord record) {
    final builder = BytesBuilder(copy: false);
    void add(String value) {
      final bytes = utf8.encode(value);
      if (bytes.length > 0xffffff) {
        throw const MessageHistoryCorruptException();
      }
      builder
        ..addByte((bytes.length >> 16) & 0xff)
        ..addByte((bytes.length >> 8) & 0xff)
        ..addByte(bytes.length & 0xff)
        ..add(bytes);
    }

    final phase = record.mlsPhase;
    add(phase == null ? '1' : '2');
    add(record.ownerUserId);
    add(record.ownerDeviceId);
    add(record.conversationId);
    add(record.senderId);
    add(record.clientMessageId);
    add(record.envelopeId == null ? '\x00' : '\x01${record.envelopeId}');
    add(
      record.conversationSeq == null ? '\x00' : '\x01${record.conversationSeq}',
    );
    add(record.createdAtRaw);
    add(record.delivery.name);
    if (phase != null) add(phase.name);
    return builder.toBytes();
  }

  static Uint8List _outboxAssociatedData({
    required String conversationId,
    required String clientMessageId,
    required String senderId,
    required String recipientId,
    required String mlsGroupIdHex,
    required String contentType,
  }) {
    final builder = BytesBuilder(copy: false);
    void add(String value) {
      final bytes = utf8.encode(value);
      if (bytes.length > 0xffffff) {
        throw const MessageHistoryCorruptException();
      }
      builder
        ..addByte((bytes.length >> 16) & 0xff)
        ..addByte((bytes.length >> 8) & 0xff)
        ..addByte(bytes.length & 0xff)
        ..add(bytes);
    }

    add('outbox-v2');
    add(conversationId);
    add(clientMessageId);
    add(senderId);
    add(recipientId);
    add(mlsGroupIdHex);
    add(contentType);
    return builder.toBytes();
  }

  static String _canonicalTime(DateTime value) =>
      value.toUtc().toIso8601String();

  static void _validateDraft(LocalMessageDraft draft) {
    _validateIdentity(
      conversationId: draft.conversationId,
      clientMessageId: draft.clientMessageId,
    );
    _textValue(draft.senderId, 'senderId');
    if (draft.envelopeId != null) {
      _textValue(draft.envelopeId!, 'envelopeId');
    }
    _checkSeq(draft.conversationSeq);
  }

  static void _validateIdentity({
    required String conversationId,
    required String clientMessageId,
  }) {
    _textValue(conversationId, 'conversationId');
    _textValue(clientMessageId, 'clientMessageId');
  }

  static String _textValue(String value, String name) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, name, '$name is empty');
    }
    return value;
  }

  static void _checkSeq(int? seq) {
    if (seq != null && seq < 0) {
      throw ArgumentError.value(seq, 'conversationSeq', 'sequence is negative');
    }
  }

  static String? _optionalText(Object? value, String name) {
    if (value == null) return null;
    if (value is! String) {
      throw ArgumentError.value(value, name, '$name must be a string');
    }
    return _textValue(value, name);
  }

  static LocalMlsPhase? _optionalPhase(Object? value) {
    if (value == null) return null;
    if (value is! LocalMlsPhase) {
      throw ArgumentError('mls phase is invalid');
    }
    return value;
  }

  static int? _optionalSeq(Object? value) {
    if (value == null) return null;
    if (value is! int) {
      throw ArgumentError.value(
        value,
        'conversationSeq',
        'sequence must be an integer',
      );
    }
    _checkSeq(value);
    return value;
  }

  static List<int>? _optionalWire(Object? value) {
    if (value == null) return null;
    if (value is! List<int>) {
      throw ArgumentError.value(
        value,
        'preparedCiphertext',
        'prepared ciphertext must be bytes',
      );
    }
    if (value.isEmpty) {
      throw ArgumentError.value(
        value,
        'preparedCiphertext',
        'prepared ciphertext is empty',
      );
    }
    return List<int>.from(value);
  }

  static String _text(Object? value) {
    if (value is! String || value.isEmpty) {
      throw const MessageHistoryCorruptException();
    }
    return value;
  }

  static String? _nullableText(Object? value) {
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      throw const MessageHistoryCorruptException();
    }
    return value;
  }

  static int? _nullableSeq(Object? value) {
    if (value == null) return null;
    if (value is! int || value < 0) {
      throw const MessageHistoryCorruptException();
    }
    return value;
  }

  static LocalMlsPhase? _phase(Object? value) {
    if (value == null) return null;
    if (value is! String) throw const MessageHistoryCorruptException();
    for (final phase in LocalMlsPhase.values) {
      if (phase.name == value) return phase;
    }
    throw const MessageHistoryCorruptException();
  }

  static LocalMessageDelivery _delivery(Object? value) {
    if (value is! String) throw const MessageHistoryCorruptException();
    for (final delivery in LocalMessageDelivery.values) {
      if (delivery.name == value) return delivery;
    }
    throw const MessageHistoryCorruptException();
  }

  static Uint8List _blob(Object? value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    throw const MessageHistoryCorruptException();
  }

  static bool _isAllZero(Uint8List bytes) {
    for (final byte in bytes) {
      if (byte != 0) return false;
    }
    return true;
  }

  static bool _constantEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Sentinel for [LocalMessageStore.update] arguments that should stay as stored.
const Object _unchanged = Object();

/// Outgoing outbox lifecycle plus inbound received.
///
/// Legacy [sending] remains readable. New writes use preparing → ready →
/// submitting → sent, or failed / uncertain / blocked.
enum LocalMessageDelivery {
  sending,
  preparing,
  encrypting,
  ready,
  submitting,
  sent,
  failed,
  uncertain,
  blocked,
  received,
}

/// MLS progress for an inbound application message. Delivery is separate.
enum LocalMlsPhase { inspected, committed }

/// Reads and writes used by inbound history. Implementations must not open
/// the OpenMLS database.
abstract interface class InboundMessageHistory {
  Future<LocalMessageRecord?> lookupByClientMessageId({
    required String conversationId,
    required String clientMessageId,
  });

  Future<LocalMessageRecord?> lookupByEnvelopeId(String envelopeId);

  Future<List<LocalMessageRecord>> listConversation(String conversationId);

  Future<LocalMessageRecord> insert(LocalMessageDraft draft);

  Future<LocalMessageRecord> markInboundState({
    required String conversationId,
    required String clientMessageId,
    LocalMlsPhase? mlsPhase,
    LocalMessageDelivery? delivery,
    Object? envelopeId = keepHistoryField,
    Object? conversationSeq = keepHistoryField,
    Object? preparedCiphertext = keepHistoryField,
    Object? mlsGroupIdHex = keepHistoryField,
    Object? outboxRecipientId = keepHistoryField,
    Object? outboxContentType = keepHistoryField,
  });
}

/// Sentinel for history updates that should leave a field unchanged.
const Object keepHistoryField = Object();

/// Plaintext message returned by the store. [toString] omits the plaintext.
class LocalMessageRecord {
  LocalMessageRecord({
    required this.ownerUserId,
    required this.ownerDeviceId,
    required this.conversationId,
    required this.senderId,
    required this.clientMessageId,
    required this.envelopeId,
    required this.conversationSeq,
    required this.createdAtRaw,
    required this.delivery,
    required this.mlsPhase,
    required this.plaintext,
    this.preparedCiphertext,
    this.mlsGroupIdHex,
    this.outboxRecipientId,
    this.outboxContentType,
  });

  final String ownerUserId;
  final String ownerDeviceId;
  final String conversationId;
  final String senderId;
  final String clientMessageId;
  final String? envelopeId;
  final int? conversationSeq;
  final String createdAtRaw;
  final LocalMessageDelivery delivery;
  final LocalMlsPhase? mlsPhase;
  final String plaintext;

  /// Decrypted MLS application wire bytes when an outbox row is present.
  final List<int>? preparedCiphertext;
  final String? mlsGroupIdHex;
  final String? outboxRecipientId;
  final String? outboxContentType;

  bool get hasPreparedOutbox =>
      preparedCiphertext != null &&
      preparedCiphertext!.isNotEmpty &&
      mlsGroupIdHex != null &&
      mlsGroupIdHex!.isNotEmpty &&
      outboxRecipientId != null &&
      outboxRecipientId!.isNotEmpty &&
      outboxContentType != null &&
      outboxContentType!.isNotEmpty;

  DateTime get createdAt => DateTime.parse(createdAtRaw).toUtc();

  LocalMessageRecord _withPlaintext(String value) {
    return LocalMessageRecord(
      ownerUserId: ownerUserId,
      ownerDeviceId: ownerDeviceId,
      conversationId: conversationId,
      senderId: senderId,
      clientMessageId: clientMessageId,
      envelopeId: envelopeId,
      conversationSeq: conversationSeq,
      createdAtRaw: createdAtRaw,
      delivery: delivery,
      mlsPhase: mlsPhase,
      plaintext: value,
      preparedCiphertext: preparedCiphertext,
      mlsGroupIdHex: mlsGroupIdHex,
      outboxRecipientId: outboxRecipientId,
      outboxContentType: outboxContentType,
    );
  }

  LocalMessageRecord _withOutbox({
    List<int>? preparedCiphertext,
    String? mlsGroupIdHex,
    String? outboxRecipientId,
    String? outboxContentType,
  }) {
    return LocalMessageRecord(
      ownerUserId: ownerUserId,
      ownerDeviceId: ownerDeviceId,
      conversationId: conversationId,
      senderId: senderId,
      clientMessageId: clientMessageId,
      envelopeId: envelopeId,
      conversationSeq: conversationSeq,
      createdAtRaw: createdAtRaw,
      delivery: delivery,
      mlsPhase: mlsPhase,
      plaintext: plaintext,
      preparedCiphertext: preparedCiphertext,
      mlsGroupIdHex: mlsGroupIdHex,
      outboxRecipientId: outboxRecipientId,
      outboxContentType: outboxContentType,
    );
  }

  @override
  String toString() =>
      'LocalMessageRecord(conversationId: $conversationId, '
      'clientMessageId: $clientMessageId, delivery: ${delivery.name}, '
      'outbox: $hasPreparedOutbox)';
}

class LocalMessageDraft {
  const LocalMessageDraft({
    required this.conversationId,
    required this.senderId,
    required this.clientMessageId,
    required this.createdAt,
    required this.delivery,
    required this.plaintext,
    this.envelopeId,
    this.conversationSeq,
    this.mlsPhase,
    this.preparedCiphertext,
    this.mlsGroupIdHex,
    this.outboxRecipientId,
    this.outboxContentType,
  });

  final String conversationId;
  final String senderId;
  final String clientMessageId;
  final String? envelopeId;
  final int? conversationSeq;
  final DateTime createdAt;
  final LocalMessageDelivery delivery;
  final LocalMlsPhase? mlsPhase;
  final String plaintext;
  final List<int>? preparedCiphertext;
  final String? mlsGroupIdHex;
  final String? outboxRecipientId;
  final String? outboxContentType;

  @override
  String toString() =>
      'LocalMessageDraft(conversationId: $conversationId, '
      'clientMessageId: $clientMessageId, delivery: ${delivery.name})';
}

class MessageHistoryKeyLossException implements Exception {
  const MessageHistoryKeyLossException();

  @override
  String toString() =>
      'MessageHistoryKeyLossException: message history key is unavailable';
}

class MessageHistoryCorruptException implements Exception {
  const MessageHistoryCorruptException();

  @override
  String toString() =>
      'MessageHistoryCorruptException: message history record is unreadable';
}

class MessageHistoryConflictException implements Exception {
  const MessageHistoryConflictException();

  @override
  String toString() =>
      'MessageHistoryConflictException: message identity already exists';
}

class MessageHistoryNotFoundException implements Exception {
  const MessageHistoryNotFoundException();

  @override
  String toString() =>
      'MessageHistoryNotFoundException: message history record is absent';
}

class MessageHistorySchemaException implements Exception {
  const MessageHistorySchemaException();

  @override
  String toString() =>
      'MessageHistorySchemaException: message history schema cannot be applied';
}
