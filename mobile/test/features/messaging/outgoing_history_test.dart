import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    tempDir = await Directory.systemTemp.createTemp('pm_out_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('outgoing and inbound rows merge without duplication', () async {
    final store = await LocalMessageStore.open(
      userId: _me,
      deviceId: _device,
      dbPath: '${tempDir.path}${Platform.pathSeparator}messages.db',
      storage: const FlutterSecureStorage(),
      factory: databaseFactoryFfi,
    );
    addTearDown(store.close);

    final engine = _ScriptedMls();
    final service = EncryptedConversationService(
      api: ApiClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/ack')) {
            return http.Response('', 204);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/envelopes')) {
            return http.Response(
              jsonEncode({
                'id': 'env-out',
                'conversation_id': _conv,
                'sender_id': _me,
                'client_message_id': 'out-1',
                'ciphertext_b64': 'BwcH',
                'content_type': MlsContentTypes.application,
                'created_at': '2026-01-01T00:00:00.000Z',
                'conversation_seq': 1,
              }),
              201,
            );
          }
          return http.Response('no', 404);
        }),
        baseUri: Uri.parse('http://example.test'),
      ),
      mls: MlsSessionManager(),
      engine: engine,
      history: store,
    )
      ..rememberGroup(_conv, 'abc')
      ..bindConversationPeer(_conv, 'peer');

    await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'from-me',
      clientMessageId: 'out-1',
      createdAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
    );

    service.bindConversationPeer(_conv, 'peer');
    await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [
        MessageEnvelope(
          id: 'env-in',
          conversationId: _conv,
          senderId: 'peer',
          clientMessageId: 'in-1',
          ciphertext: const [1],
          contentType: MlsContentTypes.application,
          createdAt: DateTime.utc(2026, 1, 1, 0, 0, 2),
          conversationSeq: 2,
        ),
      ],
    );

    final views = await service.localTranscript(
      conversationId: _conv,
      myUserId: _me,
    );
    expect(views.map((v) => v.plaintext).toList(), ['from-me', 'hi']);
    expect(views.first.delivery, ChatDeliveryState.sent);
    expect(views.first.isMine, isTrue);
    expect(views.last.delivery, ChatDeliveryState.received);
    expect(views.last.isMine, isFalse);
  });

  test('ambiguous submit timeout stays Uncertain without claiming Sent', () async {
    final store = await LocalMessageStore.open(
      userId: _me,
      deviceId: _device,
      dbPath: '${tempDir.path}${Platform.pathSeparator}timeout.db',
      storage: const FlutterSecureStorage(),
      factory: databaseFactoryFfi,
    );
    addTearDown(store.close);

    final hang = Completer<http.Response>();
    addTearDown(() {
      if (!hang.isCompleted) {
        hang.complete(http.Response('no', 500));
      }
    });
    final engine = _ScriptedMls();
    final service = EncryptedConversationService(
      api: ApiClient(
        client: MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/envelopes')) {
            return hang.future;
          }
          return http.Response('no', 404);
        }),
        baseUri: Uri.parse('http://example.test'),
      ),
      mls: MlsSessionManager(),
      engine: engine,
      history: store,
      submitTimeout: const Duration(milliseconds: 30),
    )
      ..rememberGroup(_conv, 'abc')
      ..bindConversationPeer(_conv, 'peer');

    final failed = await service.sendText(
      token: 'tok',
      conversationId: _conv,
      myUserId: _me,
      plaintext: 'maybe',
      clientMessageId: 'out-timeout',
    );
    expect(failed.delivery, ChatDeliveryState.uncertain);
    expect(failed.error, isNull);
    expect(engine.encryptCalls, 1);
    final row = (await store.listConversation(_conv)).single;
    expect(row.delivery, LocalMessageDelivery.uncertain);
    expect(row.hasPreparedOutbox, isTrue);
  });
}

class _ScriptedMls implements MlsGroupEncryptionService {
  int encryptCalls = 0;
  int processCalls = 0;
  int inspectCalls = 0;

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
  }) async {
    inspectCalls++;
    return const DecryptedApplicationMessage(plaintext: [104, 105]);
  }

  @override
  Future<DecryptedApplicationMessage?> processIncoming({
    required String groupIdHex,
    required List<int> messageBytes,
  }) async {
    processCalls++;
    return const DecryptedApplicationMessage(plaintext: [104, 105]);
  }

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

