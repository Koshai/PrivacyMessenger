import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/core/auth/auth_controller.dart';
import 'package:private_messenger/core/auth/session_store.dart';
import 'package:private_messenger/core/crypto/encryption_service.dart';
import 'package:private_messenger/core/crypto/mls_session_manager.dart';
import 'package:private_messenger/core/crypto/protocol_messages.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/auth/models/auth_identity.dart';
import 'package:private_messenger/features/auth/models/auth_session.dart';
import 'package:private_messenger/features/messaging/conversation_controller.dart';
import 'package:private_messenger/features/messaging/delivery_timing.dart';
import 'package:private_messenger/features/messaging/encrypted_conversation_service.dart';
import 'package:private_messenger/features/messaging/local_message_store.dart';
import 'package:private_messenger/features/messaging/models/envelope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '11111111-1111-4111-8111-111111111111';
const _device = '22222222-2222-4222-8222-222222222222';
const _peer = '33333333-3333-4333-8333-333333333333';
const _conv = '44444444-4444-4444-8444-444444444444';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late Directory tempDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    MlsDiagnostics.reset();
    DeliveryTiming.reset();
    tempDir = await Directory.systemTemp.createTemp('pm_outbox_safety_');
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

  test('encrypting marker is durable before OpenMLS encrypt is invoked', () async {
    final store = await openStore('encrypting-boundary');
    addTearDown(store.close);
    final engine = _BoundaryMls(store);
    final service = EncryptedConversationService(
      api: ApiClient(
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'id': 'env-1',
              'conversation_id': _conv,
              'sender_id': _me,
              'client_message_id': 'c-boundary',
              'ciphertext_b64': base64Encode(const [7, 7, 7]),
              'content_type': MlsContentTypes.application,
              'created_at': '2026-01-01T00:00:00.000Z',
              'conversation_seq': 1,
            }),
            201,
          );
        }),
        baseUri: Uri.parse('http://example.test'),
      ),
      mls: MlsSessionManager(),
      engine: engine,
      history: store,
    )
      ..rememberGroup(_conv, 'group-hex')
      ..bindConversationPeer(_conv, _peer);

    final sent = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'boundary',
      clientMessageId: 'c-boundary',
    );
    expect(sent.delivery, ChatDeliveryState.sent);
    expect(engine.sawEncryptingBeforeEncrypt, isTrue);
    expect(engine.encryptCalls, 1);
  });

  test('blocked rows stay visible after reopen and refuse unsafe retry', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}blocked.db';
    final store1 = await LocalMessageStore.open(
      userId: _me,
      deviceId: _device,
      dbPath: path,
      storage: const FlutterSecureStorage(),
      factory: databaseFactoryFfi,
    );
    await store1.insert(
      LocalMessageDraft(
        conversationId: _conv,
        senderId: _me,
        clientMessageId: 'c-blocked',
        createdAt: DateTime.utc(2026, 1, 1),
        delivery: LocalMessageDelivery.encrypting,
        plaintext: 'stuck',
      ),
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
    final engine = _ScriptedMls();
    final service = EncryptedConversationService(
      api: ApiClient(
        client: MockClient((request) async {
          fail('blocked message must not submit');
        }),
        baseUri: Uri.parse('http://example.test'),
      ),
      mls: MlsSessionManager(),
      engine: engine,
      history: store2,
    )
      ..rememberGroup(_conv, 'group-hex')
      ..bindConversationPeer(_conv, _peer);

    final views = await service.localTranscript(
      conversationId: _conv,
      myUserId: _me,
    );
    expect(views, hasLength(1));
    expect(views.single.plaintext, 'stuck');
    expect(views.single.delivery, ChatDeliveryState.blocked);
    expect(views.single.error, contains('Cannot safely retry'));

    final auth = AuthController(
      store: _FakeSessionStore(),
      validate: (_) async => AuthIdentity(
        userId: _me,
        deviceId: _device,
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
      revoke: (_) async {},
    );
    await auth.signIn(
      AuthSession(
        userId: _me,
        deviceId: _device,
        token: 'tok',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
    );
    final controller = ConversationController(
      api: ApiClient(
        client: MockClient((_) async => http.Response('no', 404)),
        baseUri: Uri.parse('http://example.test'),
      ),
      auth: auth,
      mls: MlsSessionManager(),
      peerUserId: _peer,
      peerEmail: 'peer@example.com',
      service: service,
    );
    addTearDown(controller.dispose);
    controller.conversationId = _conv;
    await controller.restoreLocalHistory();
    expect(controller.messages.single.delivery, ChatDeliveryState.blocked);

    await controller.retry('c-blocked');
    expect(engine.encryptCalls, 0);
    expect(controller.messages.single.delivery, ChatDeliveryState.blocked);
  });

  test('outbox ciphertext is AEAD-bound and absent from diagnostics', () async {
    final store = await openStore('aad');
    addTearDown(store.close);
    final engine = _ScriptedMls();
    final service = EncryptedConversationService(
      api: ApiClient(
        client: MockClient((request) async => http.Response('no', 500)),
        baseUri: Uri.parse('http://example.test'),
      ),
      mls: MlsSessionManager(),
      engine: engine,
      history: store,
    )
      ..rememberGroup(_conv, 'group-hex')
      ..bindConversationPeer(_conv, _peer);

    await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'secret-plain',
      clientMessageId: 'c-aad',
    );

    final row = (await store.listConversation(_conv)).single;
    expect(row.hasPreparedOutbox, isTrue);
    expect(row.outboxRecipientId, _peer);
    expect(row.outboxContentType, MlsContentTypes.application);

    final db = await databaseFactoryFfi.openDatabase(store.dbPath);
    addTearDown(db.close);
    final raw = (await db.query('local_messages')).single;
    final outboxBlob = raw['outbox_ciphertext'];
    expect(outboxBlob, isA<Uint8List>());
    expect(outboxBlob as Uint8List, isNot(equals(Uint8List.fromList(const [7, 7, 7]))));
    expect(utf8.decode(outboxBlob, allowMalformed: true), isNot(contains('secret-plain')));

    // Tamper AAD-bound cleartext recipient → decrypt fails closed.
    await db.update(
      'local_messages',
      {'outbox_recipient_id': 'tampered-peer'},
      where: 'client_message_id = ?',
      whereArgs: const ['c-aad'],
    );
    expect(
      () => store.lookupByClientMessageId(
        conversationId: _conv,
        clientMessageId: 'c-aad',
      ),
      throwsA(isA<MessageHistoryCorruptException>()),
    );

    final diag = MlsDiagnostics.events.map((e) => e.toString()).join('|');
    final timing = DeliveryTiming.events.map((e) => e.toString()).join('|');
    expect(diag, isNot(contains(base64Encode(const [7, 7, 7]))));
    expect(diag, isNot(contains('secret-plain')));
    expect(timing, isNot(contains(base64Encode(const [7, 7, 7]))));
    expect(timing, isNot(contains('secret-plain')));
  });

  test('uncertain is never auto-resubmitted on sync/reconnect restore', () async {
    final store = await openStore('uncertain-nosync');
    addTearDown(store.close);
    await store.insert(
      LocalMessageDraft(
        conversationId: _conv,
        senderId: _me,
        clientMessageId: 'c-uncertain',
        createdAt: DateTime.utc(2026, 1, 1),
        delivery: LocalMessageDelivery.uncertain,
        plaintext: 'maybe',
        preparedCiphertext: const [9, 9, 9],
        mlsGroupIdHex: 'group-hex',
        outboxRecipientId: _peer,
        outboxContentType: MlsContentTypes.application,
      ),
    );

    var posts = 0;
    final engine = _ScriptedMls();
    final service = EncryptedConversationService(
      api: ApiClient(
        client: MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/envelopes')) {
            posts++;
            fail('uncertain must not auto-submit');
          }
          if (request.url.path.contains('/envelopes/pending') ||
              request.url.path.endsWith('/pending')) {
            return http.Response('{"envelopes":[]}', 200);
          }
          return http.Response('{"envelopes":[]}', 200);
        }),
        baseUri: Uri.parse('http://example.test'),
      ),
      mls: MlsSessionManager(),
      engine: engine,
      history: store,
    )
      ..rememberGroup(_conv, 'group-hex')
      ..bindConversationPeer(_conv, _peer);

    await service.pullPending(token: 'tok', myUserId: _me);
    final views = await service.localTranscript(
      conversationId: _conv,
      myUserId: _me,
    );
    expect(views.single.delivery, ChatDeliveryState.uncertain);
    expect(engine.encryptCalls, 0);
    expect(posts, 0);

    // Explicit resubmit remains available and reuses outbox bytes.
    final service2 = EncryptedConversationService(
      api: ApiClient(
        client: MockClient((request) async {
          posts++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['ciphertext_b64'], base64Encode(const [9, 9, 9]));
          return http.Response(
            jsonEncode({
              'id': 'env-u',
              'conversation_id': _conv,
              'sender_id': _me,
              'client_message_id': 'c-uncertain',
              'ciphertext_b64': body['ciphertext_b64'],
              'content_type': MlsContentTypes.application,
              'created_at': '2026-01-01T00:00:00.000Z',
              'conversation_seq': 1,
            }),
            200,
          );
        }),
        baseUri: Uri.parse('http://example.test'),
      ),
      mls: MlsSessionManager(),
      engine: engine,
      history: store,
    )
      ..rememberGroup(_conv, 'group-hex')
      ..bindConversationPeer(_conv, _peer);

    final resent = await service2.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'maybe',
      clientMessageId: 'c-uncertain',
    );
    expect(resent.delivery, ChatDeliveryState.sent);
    expect(engine.encryptCalls, 0);
    expect(posts, 1);
  });
}

class _BoundaryMls implements MlsGroupEncryptionService {
  _BoundaryMls(this.store);

  final LocalMessageStore store;
  int encryptCalls = 0;
  bool sawEncryptingBeforeEncrypt = false;

  @override
  bool get isAvailable => true;

  @override
  String get backendId => 'boundary';

  @override
  Future<MlsWireMessage> encryptApplication({
    required String groupIdHex,
    required List<int> plaintext,
    List<int>? aad,
  }) async {
    encryptCalls++;
    final row = await store.lookupByClientMessageId(
      conversationId: _conv,
      clientMessageId: 'c-boundary',
    );
    sawEncryptingBeforeEncrypt =
        row?.delivery == LocalMessageDelivery.encrypting;
    return const MlsWireMessage(kind: MlsWireKind.application, bytes: [7, 7, 7]);
  }

  @override
  Future<DecryptedApplicationMessage> inspectApplication({
    required String groupIdHex,
    required List<int> messageBytes,
  }) async =>
      const DecryptedApplicationMessage(plaintext: [1]);

  @override
  Future<DecryptedApplicationMessage?> processIncoming({
    required String groupIdHex,
    required List<int> messageBytes,
  }) async =>
      null;

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

class _ScriptedMls implements MlsGroupEncryptionService {
  int encryptCalls = 0;

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
    return const MlsWireMessage(kind: MlsWireKind.application, bytes: [7, 7, 7]);
  }

  @override
  Future<DecryptedApplicationMessage> inspectApplication({
    required String groupIdHex,
    required List<int> messageBytes,
  }) async =>
      const DecryptedApplicationMessage(plaintext: [1]);

  @override
  Future<DecryptedApplicationMessage?> processIncoming({
    required String groupIdHex,
    required List<int> messageBytes,
  }) async =>
      null;

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

class _FakeSessionStore implements SessionStore {
  AuthSession? session;

  @override
  Future<void> save(AuthSession value) async => session = value;

  @override
  Future<AuthSession?> read() async => session;

  @override
  Future<void> clear() async => session = null;
}
