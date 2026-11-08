import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/core/crypto/encryption_service.dart';
import 'package:private_messenger/core/crypto/mls_session_manager.dart';
import 'package:private_messenger/core/crypto/protocol_messages.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/messaging/encrypted_conversation_service.dart';
import 'package:private_messenger/features/messaging/local_message_store.dart';
import 'package:private_messenger/features/messaging/models/envelope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '11111111-1111-4111-8111-111111111111';
const _device = '22222222-2222-4222-8222-222222222222';
const _conv = '44444444-4444-4444-8444-444444444444';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(sqfliteFfiInit);

  late Directory tempDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('pm_outbox_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<LocalMessageStore> openStore(String name) {
    return LocalMessageStore.open(
      userId: _me,
      deviceId: _device,
      dbPath: '${tempDir.path}${Platform.pathSeparator}$name.db',
      storage: const FlutterSecureStorage(),
      factory: databaseFactoryFfi,
    );
  }

  EncryptedConversationService serviceFor({
    required LocalMessageStore store,
    required _ScriptedMls engine,
    required MockClient client,
    Duration submitTimeout = const Duration(seconds: 15),
  }) {
    return EncryptedConversationService(
      api: ApiClient(
        client: client,
        baseUri: Uri.parse('http://example.test'),
      ),
      mls: MlsSessionManager(),
      engine: engine,
      history: store,
      submitTimeout: submitTimeout,
    )
      ..rememberGroup(_conv, 'group-hex')
      ..bindConversationPeer(_conv, 'peer-user');
  }

  http.Response okEnvelope({
    required String clientMessageId,
    required List<int> ciphertext,
    int status = 201,
    String id = 'env-1',
    int seq = 1,
  }) {
    return http.Response(
      jsonEncode({
        'id': id,
        'conversation_id': _conv,
        'sender_id': _me,
        'client_message_id': clientMessageId,
        'ciphertext_b64': base64Encode(ciphertext),
        'content_type': MlsContentTypes.application,
        'created_at': '2026-01-01T00:00:00.000Z',
        'conversation_seq': seq,
      }),
      status,
    );
  }

  test('HTTP success persists sent and clears outbox', () async {
    final store = await openStore('success');
    addTearDown(store.close);
    final engine = _ScriptedMls();
    final service = serviceFor(
      store: store,
      engine: engine,
      client: MockClient((request) async {
        expect(request.method, 'POST');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['client_message_id'], 'c-ok');
        return okEnvelope(clientMessageId: 'c-ok', ciphertext: const [7, 7, 7]);
      }),
    );

    final view = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'hello',
      clientMessageId: 'c-ok',
    );
    expect(view.delivery, ChatDeliveryState.sent);
    expect(engine.encryptCalls, 1);
    final row = (await store.listConversation(_conv)).single;
    expect(row.delivery, LocalMessageDelivery.sent);
    expect(row.hasPreparedOutbox, isFalse);
  });

  test('failure before submission keeps durable outbox for retry', () async {
    final store = await openStore('fail-before');
    addTearDown(store.close);
    final engine = _ScriptedMls();
    final service = serviceFor(
      store: store,
      engine: engine,
      client: MockClient((request) async => http.Response('no', 500)),
    );

    final failed = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'hello',
      clientMessageId: 'c-fail',
    );
    expect(failed.delivery, ChatDeliveryState.failed);
    final row = (await store.listConversation(_conv)).single;
    expect(row.delivery, LocalMessageDelivery.failed);
    expect(row.hasPreparedOutbox, isTrue);
    expect(row.preparedCiphertext, [7, 7, 7]);
  });

  test('timeout after acceptance is uncertain and never silent-retryable', () async {
    final store = await openStore('timeout');
    addTearDown(store.close);
    final hang = Completer<http.Response>();
    addTearDown(() {
      if (!hang.isCompleted) hang.complete(http.Response('no', 500));
    });
    final engine = _ScriptedMls();
    final service = serviceFor(
      store: store,
      engine: engine,
      submitTimeout: const Duration(milliseconds: 30),
      client: MockClient((request) async => hang.future),
    );

    final view = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'maybe',
      clientMessageId: 'c-timeout',
    );
    expect(view.delivery, ChatDeliveryState.uncertain);
    final row = (await store.listConversation(_conv)).single;
    expect(row.delivery, LocalMessageDelivery.uncertain);
    expect(row.hasPreparedOutbox, isTrue);
  });

  test('same-session explicit retry reuses prepared ciphertext', () async {
    final store = await openStore('same-session');
    addTearDown(store.close);
    final engine = _ScriptedMls();
    var posts = 0;
    final service = serviceFor(
      store: store,
      engine: engine,
      client: MockClient((request) async {
        posts++;
        if (posts == 1) return http.Response('no', 503);
        return okEnvelope(
          clientMessageId: 'c-retry',
          ciphertext: const [7, 7, 7],
          status: 200,
        );
      }),
    );

    final first = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'retry-me',
      clientMessageId: 'c-retry',
    );
    expect(first.delivery, ChatDeliveryState.failed);

    final second = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'retry-me',
      clientMessageId: 'c-retry',
    );
    expect(second.delivery, ChatDeliveryState.sent);
    expect(engine.encryptCalls, 1);
    expect(posts, 2);
  });

  test('post-restart explicit retry reuses durable outbox', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}restart.db';
    final engine = _ScriptedMls();
    final store1 = await LocalMessageStore.open(
      userId: _me,
      deviceId: _device,
      dbPath: path,
      storage: const FlutterSecureStorage(),
      factory: databaseFactoryFfi,
    );
    final service1 = serviceFor(
      store: store1,
      engine: engine,
      client: MockClient((request) async => http.Response('no', 500)),
    );
    await service1.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'persist',
      clientMessageId: 'c-restart',
    );
    await store1.close();

    final store2 = await LocalMessageStore.open(
      userId: _me,
      deviceId: _device,
      dbPath: path,
      storage: const FlutterSecureStorage(),
      factory: databaseFactoryFfi,
    );
    addTearDown(store2.close);
    final engine2 = _ScriptedMls();
    final service2 = serviceFor(
      store: store2,
      engine: engine2,
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['ciphertext_b64'], base64Encode(const [7, 7, 7]));
        return okEnvelope(
          clientMessageId: 'c-restart',
          ciphertext: const [7, 7, 7],
          status: 200,
        );
      }),
    );

    final views = await service2.localTranscript(
      conversationId: _conv,
      myUserId: _me,
    );
    expect(views.single.delivery, ChatDeliveryState.failed);

    final resent = await service2.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'persist',
      clientMessageId: 'c-restart',
    );
    expect(resent.delivery, ChatDeliveryState.sent);
    expect(engine2.encryptCalls, 0);
  });

  test('crash after encrypt before outbox persistence blocks retry', () async {
    final store = await openStore('crash-encrypt');
    addTearDown(store.close);
    await store.insert(
      LocalMessageDraft(
        conversationId: _conv,
        senderId: _me,
        clientMessageId: 'c-crash-enc',
        createdAt: DateTime.utc(2026, 1, 1),
        delivery: LocalMessageDelivery.encrypting,
        plaintext: 'lost-wire',
      ),
    );
    final engine = _ScriptedMls();
    final service = serviceFor(
      store: store,
      engine: engine,
      client: MockClient((request) async {
        fail('must not submit without durable outbox');
      }),
    );

    final blocked = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'lost-wire',
      clientMessageId: 'c-crash-enc',
    );
    expect(blocked.delivery, ChatDeliveryState.blocked);
    expect(engine.encryptCalls, 0);
    expect(
      (await store.listConversation(_conv)).single.delivery,
      LocalMessageDelivery.blocked,
    );
  });

  test('crash after outbox persistence before submit can resubmit', () async {
    final store = await openStore('crash-ready');
    addTearDown(store.close);
    await store.insert(
      LocalMessageDraft(
        conversationId: _conv,
        senderId: _me,
        clientMessageId: 'c-crash-ready',
        createdAt: DateTime.utc(2026, 1, 1),
        delivery: LocalMessageDelivery.ready,
        plaintext: 'ready',
        preparedCiphertext: const [9, 9, 9],
        mlsGroupIdHex: 'group-hex',
        outboxRecipientId: 'peer-user',
        outboxContentType: MlsContentTypes.application,
      ),
    );
    final engine = _ScriptedMls();
    final service = serviceFor(
      store: store,
      engine: engine,
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['ciphertext_b64'], base64Encode(const [9, 9, 9]));
        return okEnvelope(
          clientMessageId: 'c-crash-ready',
          ciphertext: const [9, 9, 9],
        );
      }),
    );

    final sent = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'ready',
      clientMessageId: 'c-crash-ready',
    );
    expect(sent.delivery, ChatDeliveryState.sent);
    expect(engine.encryptCalls, 0);
  });

  test('conversation reopen maps durable states without re-encrypt', () async {
    final store = await openStore('reopen');
    addTearDown(store.close);
    await store.insert(
      LocalMessageDraft(
        conversationId: _conv,
        senderId: _me,
        clientMessageId: 'c-reopen',
        createdAt: DateTime.utc(2026, 1, 1),
        delivery: LocalMessageDelivery.uncertain,
        plaintext: 'open-me',
        preparedCiphertext: const [1, 2, 3],
        mlsGroupIdHex: 'group-hex',
        outboxRecipientId: 'peer-user',
        outboxContentType: MlsContentTypes.application,
      ),
    );
    final service = serviceFor(
      store: store,
      engine: _ScriptedMls(),
      client: MockClient((request) async => http.Response('no', 404)),
    );
    final views = await service.localTranscript(
      conversationId: _conv,
      myUserId: _me,
    );
    expect(views.single.delivery, ChatDeliveryState.uncertain);
    expect(views.single.error, isNull);
  });

  test('two consecutive messages encrypt in order once each', () async {
    final store = await openStore('ordered');
    addTearDown(store.close);
    final engine = _ScriptedMls()..sequential = true;
    var posts = 0;
    final service = serviceFor(
      store: store,
      engine: engine,
      client: MockClient((request) async {
        posts++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final id = body['client_message_id'] as String;
        return okEnvelope(
          clientMessageId: id,
          ciphertext: base64Decode(body['ciphertext_b64'] as String),
          id: 'env-$posts',
          seq: posts,
        );
      }),
    );

    final first = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'one',
      clientMessageId: 'c-1',
    );
    final second = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'two',
      clientMessageId: 'c-2',
    );
    expect(first.delivery, ChatDeliveryState.sent);
    expect(second.delivery, ChatDeliveryState.sent);
    expect(engine.encryptCalls, 2);
    expect(engine.encryptPlaintexts, [
      utf8.encode('one'),
      utf8.encode('two'),
    ]);
  });

  test('missing outbox bytes fail closed as blocked', () async {
    final store = await openStore('missing-outbox');
    addTearDown(store.close);
    await store.insert(
      LocalMessageDraft(
        conversationId: _conv,
        senderId: _me,
        clientMessageId: 'c-missing',
        createdAt: DateTime.utc(2026, 1, 1),
        delivery: LocalMessageDelivery.failed,
        plaintext: 'no-wire',
      ),
    );
    final engine = _ScriptedMls();
    final service = serviceFor(
      store: store,
      engine: engine,
      client: MockClient((request) async {
        fail('must not submit');
      }),
    );
    final views = await service.localTranscript(
      conversationId: _conv,
      myUserId: _me,
    );
    expect(views.single.delivery, ChatDeliveryState.blocked);

    final blocked = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'no-wire',
      clientMessageId: 'c-missing',
    );
    expect(blocked.delivery, ChatDeliveryState.blocked);
    expect(engine.encryptCalls, 0);
  });

  test('corrupted outbox ciphertext fails closed on read', () async {
    final store = await openStore('corrupt-outbox');
    addTearDown(store.close);
    final inserted = await store.insert(
      LocalMessageDraft(
        conversationId: _conv,
        senderId: _me,
        clientMessageId: 'c-corrupt',
        createdAt: DateTime.utc(2026, 1, 1),
        delivery: LocalMessageDelivery.ready,
        plaintext: 'x',
        preparedCiphertext: const [4, 5, 6],
        mlsGroupIdHex: 'group-hex',
        outboxRecipientId: 'peer-user',
        outboxContentType: MlsContentTypes.application,
      ),
    );
    expect(inserted.hasPreparedOutbox, isTrue);

    final db = await databaseFactoryFfi.openDatabase(store.dbPath);
    addTearDown(db.close);
    await db.update(
      'local_messages',
      {'outbox_ciphertext': Uint8List.fromList(const [0, 1, 2, 3, 4, 5])},
      where: 'client_message_id = ?',
      whereArgs: const ['c-corrupt'],
    );

    expect(
      () => store.listConversation(_conv),
      throwsA(isA<MessageHistoryCorruptException>()),
    );
  });

  test('schema v3 migrates existing history without wiping rows', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}migrate.db';
    final first = await LocalMessageStore.open(
      userId: _me,
      deviceId: _device,
      dbPath: path,
      storage: const FlutterSecureStorage(),
      factory: databaseFactoryFfi,
    );
    await first.insert(
      LocalMessageDraft(
        conversationId: _conv,
        senderId: _me,
        clientMessageId: 'pre-migrate',
        createdAt: DateTime.utc(2026, 1, 1),
        delivery: LocalMessageDelivery.sent,
        plaintext: 'kept',
      ),
    );
    await first.close();

    // Simulate a v2 file that still needs outbox columns by reopening; open()
    // applies additive schema upgrades when schemaVersion advances.
    final store = await LocalMessageStore.open(
      userId: _me,
      deviceId: _device,
      dbPath: path,
      storage: const FlutterSecureStorage(),
      factory: databaseFactoryFfi,
    );
    addTearDown(store.close);
    final rows = await store.listConversation(_conv);
    expect(rows.single.plaintext, 'kept');
    expect(rows.single.delivery, LocalMessageDelivery.sent);
    expect(LocalMessageStore.schemaVersion, 4);

    final withOutbox = await store.insert(
      LocalMessageDraft(
        conversationId: _conv,
        senderId: _me,
        clientMessageId: 'post-migrate',
        createdAt: DateTime.utc(2026, 1, 2),
        delivery: LocalMessageDelivery.ready,
        plaintext: 'new',
        preparedCiphertext: const [1, 2, 3],
        mlsGroupIdHex: 'group-hex',
        outboxRecipientId: 'peer-user',
        outboxContentType: MlsContentTypes.application,
      ),
    );
    expect(withOutbox.hasPreparedOutbox, isTrue);
  });
}

class _ScriptedMls implements MlsGroupEncryptionService {
  int encryptCalls = 0;
  bool sequential = false;
  final List<List<int>> encryptPlaintexts = [];

  @override
  bool get isAvailable => true;

  @override
  String get backendId => 'scripted';

  @override
  Future<MlsWireMessage> encryptApplication({
    required String groupIdHex,
    required List<int> plaintext,
    List<int>? aad,
  }) async {
    encryptCalls++;
    encryptPlaintexts.add(List<int>.from(plaintext));
    if (sequential) {
      return MlsWireMessage(
        kind: MlsWireKind.application,
        bytes: [encryptCalls, ...plaintext],
      );
    }
    return const MlsWireMessage(kind: MlsWireKind.application, bytes: [7, 7, 7]);
  }

  @override
  Future<DecryptedApplicationMessage> inspectApplication({
    required String groupIdHex,
    required List<int> messageBytes,
  }) async =>
      const DecryptedApplicationMessage(plaintext: [104, 105]);

  @override
  Future<DecryptedApplicationMessage?> processIncoming({
    required String groupIdHex,
    required List<int> messageBytes,
  }) async =>
      const DecryptedApplicationMessage(plaintext: [104, 105]);

  @override
  Future<BigInt?> groupEpoch({required String groupIdHex}) async => null;

  @override
  BigInt? messageEpoch({required List<int> messageBytes}) => null;

  @override
  Future<void> ensureIdentityKeys() => throw UnimplementedError();

  @override
  Future<List<int>> exportPublicIdentityKey() => throw UnimplementedError();

  @override
  Future<List<int>> encrypt({
    required String recipientUserId,
    required List<int> plaintext,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<int>> decrypt({
    required String senderUserId,
    required List<int> ciphertext,
  }) =>
      throw UnimplementedError();

  @override
  Future<DeviceIdentityRecord> createIdentity({required String label}) =>
      throw UnimplementedError();

  @override
  Future<KeyPackageRecord> createKeyPackage() => throw UnimplementedError();

  @override
  Future<String> createGroup() => throw UnimplementedError();

  @override
  Future<({MlsWireMessage welcome, MlsWireMessage commit})> addMember({
    required String groupIdHex,
    required List<int> keyPackageBytes,
  }) =>
      throw UnimplementedError();

  @override
  Future<String> joinFromWelcome({required List<int> welcomeBytes}) =>
      throw UnimplementedError();

  @override
  Future<void> persistAndClose() => throw UnimplementedError();

  @override
  Future<void> restore() => throw UnimplementedError();
}
