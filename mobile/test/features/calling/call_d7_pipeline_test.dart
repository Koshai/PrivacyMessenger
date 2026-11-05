import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openmls/openmls.dart';
import 'package:private_messenger/core/crypto/mls_session_manager.dart';
import 'package:private_messenger/core/crypto/openmls/mls_device_harness.dart';
import 'package:private_messenger/core/crypto/openmls/openmls_encryption_service.dart';
import 'package:private_messenger/core/crypto/protocol_messages.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_auth_session.dart';
import 'package:private_messenger/features/calling/call_binding_inbox.dart';
import 'package:private_messenger/features/calling/call_key_binding.dart';
import 'package:private_messenger/features/messaging/encrypted_conversation_service.dart';
import 'package:private_messenger/features/messaging/models/envelope.dart';

const _alice = '11111111-1111-4111-8111-111111111111';
const _aliceDev = '22222222-2222-4222-8222-222222222222';
const _bob = '33333333-3333-4333-8333-333333333333';
const _conv = '44444444-4444-4444-8444-444444444444';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pm_d7_mls_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('inbox encrypts, bounds, expires, and survives a new instance', () async {
    final clock = DateTime.utc(2026, 11, 5, 12);
    final store = MemoryCallAuthStore();
    final inbox = CallBindingInbox(
      store: store,
      clock: () => clock,
      maxEntries: 2,
      ttl: const Duration(minutes: 3),
    );
    await inbox.put(_record('a'));
    await inbox.put(_record('b'));
    await inbox.put(_record('c'));
    expect(await inbox.length(), 2);
    expect(await inbox.contains('a'), isFalse);
    expect(await inbox.contains('c'), isTrue);
    final raw = store.values[CallBindingInbox.payloadKey]!;
    expect(raw.contains('sender_user_id'), isFalse);
    expect(raw.contains(_alice), isFalse);

    final restarted = CallBindingInbox(
      store: store,
      clock: () => clock,
      maxEntries: 2,
      ttl: const Duration(minutes: 3),
    );
    final found = await restarted.find(senderUserId: _alice, senderDeviceId: _aliceDev);
    expect(found?.envelopeId, 'c');

    final later = CallBindingInbox(
      store: store,
      clock: () => clock.add(const Duration(minutes: 4)),
      maxEntries: 2,
      ttl: const Duration(minutes: 3),
    );
    expect(await later.find(senderUserId: _alice, senderDeviceId: _aliceDev), isNull);
    expect(await later.length(), 0);

    await restarted.clear();
    expect(store.values.containsKey(CallBindingInbox.payloadKey), isFalse);
    expect(store.values.containsKey(CallBindingInbox.keyKey), isFalse);
  });

  test('chat sync and call setup share one OpenMLS decrypt', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await alice.createGroup();
    await bob.join((await alice.invite(await bob.keyPackage())).welcome);

    final statement = bindingStatementBytes(
      userId: _alice,
      deviceId: _aliceDev,
      callKey: List<int>.filled(32, 7),
      mls: List<int>.filled(32, 4),
    );
    final signature = List<int>.filled(64, 9);
    final bindingWire = await alice.service.encryptApplication(
      groupIdHex: alice.groupIdHex!,
      plaintext: <int>[...signature, ...statement],
    );
    final chatWire = await alice.sendText('hello bob');
    final binding = _envelope(
      id: 'bind-1',
      seq: 1,
      type: MlsContentTypes.callKeyBinding,
      bytes: bindingWire.bytes,
      at: DateTime.utc(2026, 11, 5, 12, 0, 2),
    );
    final chat = _envelope(
      id: 'chat-1',
      seq: 2,
      type: MlsContentTypes.application,
      bytes: chatWire.bytes,
      at: DateTime.utc(2026, 11, 5, 12, 0, 1),
    );

    final acks = <String>[];
    var sent = false;
    final api = ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/ack')) {
          acks.add(request.url.path);
          return http.Response('', 204);
        }
        if (request.url.path.endsWith('/pending')) {
          return http.Response(jsonEncode({'envelopes': [_json(binding)]}), 200);
        }
        if (request.method == 'POST' && request.url.path == '/conversations') {
          return http.Response(
            jsonEncode({
              'conversation_id': _conv,
              'created_at': DateTime.utc(2026, 11, 5).toIso8601String(),
              'mls_group_id_hex': bob.groupIdHex,
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path.endsWith('/envelopes')) {
          sent = true;
          return http.Response(jsonEncode(_json(binding)), 201);
        }
        return http.Response('no', 404);
      }),
      baseUri: Uri.parse('http://example.test'),
    );
    final store = MemoryCallAuthStore();
    final inbox = CallBindingInbox(store: store);
    final pipeline = EncryptedConversationService(
      api: api,
      mls: MlsSessionManager(),
      inbox: inbox,
      engine: bob.service,
    );
    pipeline.rememberGroup(_conv, bob.groupIdHex!);
    pipeline.bindConversationPeer(_conv, _alice);

    final channel = MlsCallKeyChannel(
      api: api,
      mls: _EngineHolder(bob.service),
      token: () => 'tok',
      pipeline: pipeline,
      inbox: inbox,
      myUserId: () => _bob,
    );
    final exchangeFuture = channel.exchange(
      peerUserId: _alice,
      peerDeviceId: _aliceDev,
      localStatement: statement,
      localSignature: signature,
    );
    while (!sent) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final views = await pipeline.ingestEnvelopes(
      token: 'tok',
      myUserId: _bob,
      envelopes: [chat, binding, binding],
    );
    final peer = await exchangeFuture;
    expect(peer, isNotNull);
    expect(peer!.statement, statement);
    expect(views.map((m) => m.plaintext), ['hello bob']);
    expect(views.any((m) => m.plaintext.contains('call-key')), isFalse);
    expect(pipeline.keyChangeWarning, isNull);
    expect(acks.where((path) => path.contains('bind-1')).length, 1);

    final again = await pipeline.ingestEnvelopes(
      token: 'tok',
      myUserId: _bob,
      envelopes: [binding, chat],
    );
    expect(again, isEmpty);
    expect(pipeline.keyChangeWarning, isNull);
    expect(await inbox.length(), 1);
  });

  test('a crash after the inbox write acks on restart without a second decrypt', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await alice.createGroup();
    await bob.join((await alice.invite(await bob.keyPackage())).welcome);
    final statement = bindingStatementBytes(
      userId: _alice,
      deviceId: _aliceDev,
      callKey: List<int>.filled(32, 3),
      mls: List<int>.filled(32, 5),
    );
    final wire = await alice.service.encryptApplication(
      groupIdHex: alice.groupIdHex!,
      plaintext: <int>[...List<int>.filled(64, 1), ...statement],
    );
    final env = _envelope(
      id: 'bind-crash',
      seq: 1,
      type: MlsContentTypes.callKeyBinding,
      bytes: wire.bytes,
      at: DateTime.utc(2026, 11, 5, 12),
    );
    var failAck = true;
    final store = MemoryCallAuthStore();
    final inbox = CallBindingInbox(store: store);
    final firstApi = _api(onAck: () {
      if (failAck) {
        failAck = false;
        return http.Response('down', 500);
      }
      return http.Response('', 204);
    });
    final first = EncryptedConversationService(
      api: firstApi,
      mls: MlsSessionManager(),
      inbox: inbox,
      engine: bob.service,
    );
    first.rememberGroup(_conv, bob.groupIdHex!);
    first.bindConversationPeer(_conv, _alice);
    await first.ingestEnvelopes(token: 'tok', myUserId: _bob, envelopes: [env]);
    expect(first.keyChangeWarning, isNotNull);
    expect(await inbox.find(senderUserId: _alice, senderDeviceId: _aliceDev), isNotNull);

    var acked = false;
    final second = EncryptedConversationService(
      api: _api(onAck: () {
        acked = true;
        return http.Response('', 204);
      }),
      mls: MlsSessionManager(),
      inbox: CallBindingInbox(store: store),
      engine: bob.service,
    );
    second.rememberGroup(_conv, bob.groupIdHex!);
    second.bindConversationPeer(_conv, _alice);
    final views = await second.ingestEnvelopes(token: 'tok', myUserId: _bob, envelopes: [env]);
    expect(views, isEmpty);
    expect(second.keyChangeWarning, isNull);
    expect(acked, isTrue);
    expect(
      (await inbox.find(senderUserId: _alice, senderDeviceId: _aliceDev))?.statement,
      statement,
    );
  });

  test('a binding whose account does not match the sender is not a chat message', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await alice.createGroup();
    await bob.join((await alice.invite(await bob.keyPackage())).welcome);
    final statement = bindingStatementBytes(
      userId: _bob,
      deviceId: _aliceDev,
      callKey: List<int>.filled(32, 3),
      mls: List<int>.filled(32, 5),
    );
    final wire = await alice.service.encryptApplication(
      groupIdHex: alice.groupIdHex!,
      plaintext: <int>[...List<int>.filled(64, 2), ...statement],
    );
    final inbox = CallBindingInbox(store: MemoryCallAuthStore());
    final pipeline = EncryptedConversationService(
      api: _api(onAck: () => http.Response('', 204)),
      mls: MlsSessionManager(),
      inbox: inbox,
      engine: bob.service,
    );
    pipeline.rememberGroup(_conv, bob.groupIdHex!);
    pipeline.bindConversationPeer(_conv, _alice);
    final views = await pipeline.ingestEnvelopes(
      token: 'tok',
      myUserId: _bob,
      envelopes: [
        _envelope(
          id: 'bind-wrong',
          seq: 1,
          type: MlsContentTypes.callKeyBinding,
          bytes: wire.bytes,
          at: DateTime.utc(2026, 11, 5, 12),
        ),
      ],
    );
    expect(views, isEmpty);
    expect(await inbox.find(senderUserId: _alice, senderDeviceId: _aliceDev), isNull);
    expect(await inbox.contains('bind-wrong'), isTrue);
  });
}

StoredCallBinding _record(String id) {
  return StoredCallBinding(
    envelopeId: id,
    conversationId: _conv,
    senderUserId: _alice,
    senderDeviceId: _aliceDev,
    signature: List<int>.filled(64, 1),
    statement: bindingStatementBytes(
      userId: _alice,
      deviceId: _aliceDev,
      callKey: List<int>.filled(32, 1),
      mls: List<int>.filled(32, 2),
    ),
    storedAt: DateTime.utc(2026, 11, 5, 12),
    rejected: false,
  );
}

Map<String, dynamic> _json(MessageEnvelope env) => {
      'id': env.id,
      'conversation_id': env.conversationId,
      'sender_id': env.senderId,
      'client_message_id': env.clientMessageId,
      'ciphertext_b64': base64Encode(env.ciphertext),
      'content_type': env.contentType,
      'created_at': env.createdAt.toIso8601String(),
      'conversation_seq': env.conversationSeq,
    };

MessageEnvelope _envelope({
  required String id,
  required int seq,
  required String type,
  required List<int> bytes,
  required DateTime at,
}) {
  return MessageEnvelope(
    id: id,
    conversationId: _conv,
    senderId: _alice,
    clientMessageId: id,
    ciphertext: bytes,
    contentType: type,
    createdAt: at,
    conversationSeq: seq,
  );
}

ApiClient _api({required http.Response Function() onAck}) {
  return ApiClient(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/ack')) return onAck();
      return http.Response('no', 404);
    }),
    baseUri: Uri.parse('http://example.test'),
  );
}

/// Test stand-in that exposes an already-open MLS engine.
class _EngineHolder extends MlsSessionManager {
  _EngineHolder(this._service);

  final OpenMlsEncryptionService _service;

  @override
  OpenMlsEncryptionService? get service => _service;
}
