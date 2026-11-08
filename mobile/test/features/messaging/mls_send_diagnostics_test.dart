import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
import 'package:private_messenger/features/messaging/encrypted_conversation_service.dart';
import 'package:private_messenger/features/messaging/local_message_store.dart';
import 'package:private_messenger/features/messaging/models/envelope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '11111111-1111-4111-8111-111111111111';
const _device = '22222222-2222-4222-8222-222222222222';
const _peer = '33333333-3333-4333-8333-333333333333';
const _conv = '44444444-4444-4444-8444-444444444444';
const _secret = 'SECRET-PLAINTEXT';

class _FakeSessionStore implements SessionStore {
  AuthSession? session;

  @override
  Future<void> save(AuthSession value) async => session = value;

  @override
  Future<AuthSession?> read() async => session;

  @override
  Future<void> clear() async => session = null;
}

class _SecretLeak implements Exception {
  @override
  String toString() => _secret;
}

class _ScriptedMls implements MlsGroupEncryptionService {
  _ScriptedMls({
    this.encryptError,
    this.joinError,
    this.processError,
    this.inspectError,
    this.returnNull = false,
  });

  Object? encryptError;
  Object? joinError;
  Object? processError;
  Object? inspectError;
  bool returnNull;
  Future<void>? encryptGate;
  int encryptCalls = 0;
  int joinCalls = 0;
  int processCalls = 0;
  int inspectCalls = 0;
  BigInt? scriptedGroupEpoch;
  BigInt? scriptedMessageEpoch;

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
    final gate = encryptGate;
    if (gate != null) await gate;
    if (encryptError != null) throw encryptError!;
    return const MlsWireMessage(kind: MlsWireKind.application, bytes: [7, 7, 7]);
  }

  @override
  Future<String> joinFromWelcome({required List<int> welcomeBytes}) async {
    joinCalls++;
    if (joinError != null) throw joinError!;
    return 'abc';
  }

  @override
  Future<DecryptedApplicationMessage> inspectApplication({
    required String groupIdHex,
    required List<int> messageBytes,
  }) async {
    inspectCalls++;
    if (inspectError != null) throw inspectError!;
    return const DecryptedApplicationMessage(plaintext: [104, 105]);
  }

  @override
  Future<DecryptedApplicationMessage?> processIncoming({
    required String groupIdHex,
    required List<int> messageBytes,
  }) async {
    processCalls++;
    if (processError != null) throw processError!;
    if (returnNull) return null;
    return const DecryptedApplicationMessage(plaintext: [104, 105]);
  }

  @override
  Future<BigInt?> groupEpoch({required String groupIdHex}) async =>
      scriptedGroupEpoch;

  @override
  BigInt? messageEpoch({required List<int> messageBytes}) =>
      scriptedMessageEpoch;

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
  Future<void> persistAndClose() => throw UnimplementedError();

  @override
  Future<void> restore() => throw UnimplementedError();
}

void main() {
  final logs = <String>[];
  late DebugPrintCallback previousDebugPrint;

  setUpAll(sqfliteFfiInit);

  setUp(() {
    logs.clear();
    MlsDiagnostics.reset();
    previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      logs.add(message ?? '');
    };
  });

  tearDown(() {
    debugPrint = previousDebugPrint;
  });

  test('encryption failure marks the optimistic message failed', () async {
    final engine = _ScriptedMls(encryptError: _SecretLeak());
    final harness = await _harness(engine: engine);
    addTearDown(harness.dispose);
    var notes = 0;
    harness.controller.addListener(() => notes++);

    await harness.controller.send('hello');

    expect(harness.posts, 0);
    expect(engine.encryptCalls, 1);
    expect(harness.controller.messages, hasLength(1));
    final message = harness.controller.messages.single;
    expect(message.delivery, ChatDeliveryState.failed);
    expect(message.error, isNull);
    expect(message.delivery, ChatDeliveryState.failed);
    expect(message.error, isNot(contains(_secret)));
    expect(notes, greaterThanOrEqualTo(2));
    expect(
      MlsDiagnostics.events.map((e) => e.stage),
      contains('encrypt_application'),
    );
    expect(
      MlsDiagnostics.events.map((e) => e.exceptionType),
      contains('_SecretLeak'),
    );
    expect(logs.join('\n'), isNot(contains(_secret)));
    expect(logs.join('\n'), contains('#'));
  });

  test('API submission failure marks the optimistic message failed', () async {
    final engine = _ScriptedMls();
    final harness = await _harness(engine: engine, failPosts: 1);
    addTearDown(harness.dispose);

    await harness.controller.send('hello');

    expect(engine.encryptCalls, 1);
    expect(harness.posts, 1);
    expect(harness.controller.messages, hasLength(1));
    expect(
      harness.controller.messages.single.delivery,
      ChatDeliveryState.failed,
    );
    expect(harness.controller.messages.single.error, isNull);
    final event = MlsDiagnostics.events.singleWhere(
      (e) => e.stage == 'send_envelope',
    );
    expect(event.exceptionType, 'ApiException.server.500');
    expect(logs.join('\n'), isNot(contains('SECRET-BODY')));
    expect(logs.join('\n'), isNot(contains('hello')));
  });

  test('successful encryption and submission marks the message sent', () async {
    final engine = _ScriptedMls();
    final harness = await _harness(engine: engine);
    addTearDown(harness.dispose);

    await harness.controller.send('hello');

    expect(engine.encryptCalls, 1);
    expect(harness.posts, 1);
    expect(harness.controller.messages, hasLength(1));
    final message = harness.controller.messages.single;
    expect(message.delivery, ChatDeliveryState.sent);
    expect(message.serverEnvelopeId, 'env-1');
    expect(MlsDiagnostics.events, isEmpty);
  });

  test('retry resubmits one prepared message and does not repeat success', () async {
    final engine = _ScriptedMls();
    final harness = await _harness(engine: engine, failPosts: 1);
    addTearDown(harness.dispose);

    await harness.controller.send('hello');
    expect(
      harness.controller.messages.single.delivery,
      ChatDeliveryState.failed,
    );
    final id = harness.controller.messages.single.clientMessageId;

    await harness.controller.retry(id);

    expect(harness.controller.messages, hasLength(1));
    expect(harness.controller.messages.single.clientMessageId, id);
    expect(harness.controller.messages.single.delivery, ChatDeliveryState.sent);
    expect(engine.encryptCalls, 1);
    expect(harness.posts, 2);

    await harness.controller.retry(id);
    expect(harness.controller.messages, hasLength(1));
    expect(engine.encryptCalls, 1);
    expect(harness.posts, 2);
  });

  test('disposal during encryption does not update or duplicate the message', () async {
    final gate = Completer<void>();
    final engine = _ScriptedMls()..encryptGate = gate.future;
    final harness = await _harness(engine: engine);

    final pending = harness.controller.send('hello');
    await _until(() => harness.controller.messages.isNotEmpty);
    expect(
      harness.controller.messages.single.delivery,
      ChatDeliveryState.sending,
    );
    harness.dispose();
    gate.complete();
    await pending;

    expect(harness.controller.messages, hasLength(1));
    expect(
      harness.controller.messages.single.delivery,
      ChatDeliveryState.sending,
    );
  });

  test('welcome, commit, and application failures are diagnostic and unacked', () async {
    final welcomeAcks = <String>[];
    final welcome = _ScriptedMls(joinError: _SecretLeak());
    final welcomeService = _service(welcome, acks: welcomeAcks);
    welcomeService.bindConversationPeer(_conv, _peer);
    await welcomeService.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [_env('w', 3, MlsContentTypes.welcome)],
    );
    expect(welcomeAcks, isEmpty);
    expect(
      welcomeService.keyChangeWarning,
      EncryptedConversationService.processingWarning,
    );
    expect(welcomeService.keyChangeWarning, isNot(contains('safety number')));
    expect(_event('welcome_join').contentType, MlsContentTypes.welcome);
    expect(_event('welcome_join').conversationSeq, 3);
    expect(_event('welcome_join').exceptionType, '_SecretLeak');

    MlsDiagnostics.reset();
    final commitAcks = <String>[];
    final commit = _ScriptedMls(processError: _SecretLeak());
    final commitService = _service(commit, acks: commitAcks);
    commitService.bindConversationPeer(_conv, _peer);
    commitService.rememberGroup(_conv, 'abc');
    commitService.bindConversationPeer(_conv, _peer);
    await commitService.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [_env('c', 4, MlsContentTypes.commit)],
    );
    expect(commitAcks, isEmpty);
    expect(commit.inspectCalls, 0);
    expect(
      commitService.keyChangeWarning,
      EncryptedConversationService.processingWarning,
    );
    expect(_event('commit_process').exceptionType, '_SecretLeak');
    expect(_event('commit_process').conversationSeq, 4);

    MlsDiagnostics.reset();
    final applicationAcks = <String>[];
    final application = _ScriptedMls(processError: _SecretLeak());
    final applicationService = _service(application, acks: applicationAcks);
    applicationService.bindConversationPeer(_conv, _peer);
    applicationService.rememberGroup(_conv, 'abc');
    applicationService.bindConversationPeer(_conv, _peer);
    await applicationService.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [_env('a', 5, MlsContentTypes.application)],
    );
    expect(applicationAcks, isEmpty);
    expect(
      applicationService.keyChangeWarning,
      EncryptedConversationService.processingWarning,
    );
    expect(
      _event('application_decrypt').contentType,
      MlsContentTypes.application,
    );
    expect(_event('application_decrypt').conversationSeq, 5);
    expect(logs.join('\n'), isNot(contains(_secret)));
  });

  test('a Commit for the current epoch is kept when processing fails', () async {
    final acks = <String>[];
    final engine = _ScriptedMls()
      ..scriptedGroupEpoch = BigInt.one
      ..scriptedMessageEpoch = BigInt.one
      ..processError = _SecretLeak();
    final service = _service(engine, acks: acks);
    service.bindConversationPeer(_conv, _peer);
    service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
    await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [_env('c', 2, MlsContentTypes.commit)],
    );
    expect(acks, isEmpty);
    expect(engine.processCalls, 1);
    expect(
      service.keyChangeWarning,
      EncryptedConversationService.processingWarning,
    );
    expect(_event('commit_process').exceptionType, '_SecretLeak');
    expect(logs.join('\n'), isNot(contains(_secret)));

    await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [_env('c', 2, MlsContentTypes.commit)],
    );
    expect(engine.processCalls, 1);
    expect(acks, isEmpty);
  });

  test('a Commit from an older epoch is acknowledged without processing', () async {
    final acks = <String>[];
    final engine = _ScriptedMls()
      ..scriptedGroupEpoch = BigInt.two
      ..scriptedMessageEpoch = BigInt.one
      ..processError = _SecretLeak();
    final service = _service(engine, acks: acks);
    service.bindConversationPeer(_conv, _peer);
    await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [_env('w', 1, MlsContentTypes.welcome)],
    );
    expect(acks, ['w']);
    engine.processError = _SecretLeak();
    await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [_env('c', 2, MlsContentTypes.commit)],
    );
    expect(acks, ['w', 'c']);
    expect(engine.processCalls, 0);
    expect(service.keyChangeWarning, isNull);
    expect(MlsDiagnostics.events, isEmpty);
  });

  test('the initiator skips its own Welcome and Commit', () async {
    final acks = <String>[];
    final engine = _ScriptedMls(joinError: _SecretLeak(), processError: _SecretLeak());
    final service = _service(engine, acks: acks);
    service.bindConversationPeer(_conv, _peer);
    service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
    await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [
        _env('w', 1, MlsContentTypes.welcome, sender: _me),
        _env('c', 2, MlsContentTypes.commit, sender: _me),
      ],
    );
    expect(engine.joinCalls, 0);
    expect(engine.processCalls, 0);
    expect(acks, isEmpty);
    expect(service.keyChangeWarning, isNull);
    expect(MlsDiagnostics.events, isEmpty);
  });

  test('a pending Welcome is joined once', () async {
    final acks = <String>[];
    final engine = _ScriptedMls();
    final service = _service(engine, acks: acks);
    service.bindConversationPeer(_conv, _peer);
    final welcome = _env('w', 1, MlsContentTypes.welcome);
    await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [welcome, welcome],
    );
    await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [welcome],
    );
    expect(engine.joinCalls, 1);
    expect(acks, ['w']);
    expect(service.keyChangeWarning, isNull);
  });

  test('acknowledged application history is not decrypted by a new service', () async {
    final history = [_env('a', 4, MlsContentTypes.application)];
    final selected = selectEnvelopesForIngest(history: history, pending: const []);
    expect(selected, isEmpty);

    final engine = _ScriptedMls(processError: _SecretLeak());
    final service = _service(engine, acks: []);
    service.bindConversationPeer(_conv, _peer);
    service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
    final views = await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: selected,
    );
    expect(views, isEmpty);
    expect(engine.processCalls, 0);
    expect(service.keyChangeWarning, isNull);
    expect(MlsDiagnostics.events, isEmpty);
  });

  test('one pending application envelope is decrypted once', () async {
    final application = _env('a', 4, MlsContentTypes.application);
    final selected = selectEnvelopesForIngest(
      history: [application, application],
      pending: [application],
    );
    expect(selected, hasLength(1));

    final acks = <String>[];
    final engine = _ScriptedMls();
    final service = _service(engine, acks: acks);
    service.bindConversationPeer(_conv, _peer);
    service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
    final views = await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: selected,
    );
    expect(views, hasLength(1));
    expect(views.single.plaintext, 'hi');
    expect(views.single.delivery, ChatDeliveryState.received);
    expect(engine.inspectCalls, 1);
    expect(engine.processCalls, 1);
    expect(acks, ['a']);
    expect(service.keyChangeWarning, isNull);
  });

  test('a pending application envelope absent from history is processed', () async {
    final application = _env('fresh', 6, MlsContentTypes.application);
    final selected = selectEnvelopesForIngest(
      history: [_env('old', 4, MlsContentTypes.application)],
      pending: [application],
    );
    expect(selected.map((envelope) => envelope.id), ['fresh']);

    final acks = <String>[];
    final engine = _ScriptedMls();
    final service = _service(engine, acks: acks);
    service.bindConversationPeer(_conv, _peer);
    service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
    final views = await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: selected,
    );
    expect(views.single.serverEnvelopeId, 'fresh');
    expect(engine.processCalls, 1);
    expect(acks, ['fresh']);
  });

  test('concurrent ingestion of one pending envelope decrypts once', () async {
    final acks = <String>[];
    final engine = _ScriptedMls();
    final service = _service(engine, acks: acks);
    service.bindConversationPeer(_conv, _peer);
    service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
    final envelope = _env('a', 4, MlsContentTypes.application);
    final results = await Future.wait([
      service.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [envelope],
      ),
      service.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [envelope],
      ),
    ]);
    expect(engine.processCalls, 1);
    expect(acks, ['a']);
    expect(results.expand((views) => views), hasLength(1));
  });

  test('failed application decryption is not acknowledged and can be retried', () async {
    final envelope = _env('a', 4, MlsContentTypes.application);
    final engine = _ScriptedMls(processError: _SecretLeak());
    final firstAcks = <String>[];
    final first = _service(engine, acks: firstAcks);
    first.bindConversationPeer(_conv, _peer);
    first.rememberGroup(_conv, 'abc');
      first.bindConversationPeer(_conv, _peer);
    final failed = await first.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [envelope],
    );
    expect(failed, isEmpty);
    expect(firstAcks, isEmpty);
    expect(engine.processCalls, 1);
    expect(first.keyChangeWarning, EncryptedConversationService.processingWarning);

    engine.processError = null;
    final secondAcks = <String>[];
    final second = _service(engine, acks: secondAcks);
    second.bindConversationPeer(_conv, _peer);
    second.rememberGroup(_conv, 'abc');
      second.bindConversationPeer(_conv, _peer);
    final retried = await second.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [envelope],
    );
    expect(retried, hasLength(1));
    expect(secondAcks, ['a']);
    expect(engine.processCalls, 2);
  });

  test('the sender can encrypt after the group exists', () async {
    final engine = _ScriptedMls();
    final harness = await _harness(engine: engine);
    addTearDown(harness.dispose);
    await harness.service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [
        _env('w', 1, MlsContentTypes.welcome, sender: _me),
        _env('c', 2, MlsContentTypes.commit, sender: _me),
      ],
    );
    expect(engine.joinCalls, 0);
    expect(engine.processCalls, 0);

    await harness.controller.send('hello');

    expect(harness.controller.messages.single.delivery, ChatDeliveryState.sent);
    expect(engine.encryptCalls, 1);
    expect(harness.service.keyChangeWarning, isNull);
  });

  test('an existing safety-number warning is not replaced by a decrypt failure', () async {
    final acks = <String>[];
    final engine = _ScriptedMls(returnNull: true);
    final service = _service(engine, acks: acks);
    service.bindConversationPeer(_conv, _peer);
    service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
    service.keyChangeWarning =
        'Safety number changed for this contact. Verify before continuing.';
    await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [_env('a', 8, MlsContentTypes.application)],
    );
    expect(acks, isEmpty);
    expect(
      service.keyChangeWarning,
      'Safety number changed for this contact. Verify before continuing.',
    );
    expect(_event('application_decrypt').exceptionType, 'StateError');
  });

  group('inbound local history', () {
    late Directory tempDir;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('pm_inbound_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('inspects, stores, processes, and acknowledges one new envelope', () async {
      final store = await _openHistory(tempDir);
      addTearDown(store.close);
      final acks = <String>[];
      final engine = _ScriptedMls();
      final service = _service(engine, acks: acks, history: store);
      service.bindConversationPeer(_conv, _peer);
      service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);

      final views = await service.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [_env('a', 4, MlsContentTypes.application)],
      );

      expect(views, hasLength(1));
      expect(views.single.plaintext, 'hi');
      expect(views.single.delivery, ChatDeliveryState.received);
      expect(engine.inspectCalls, 1);
      expect(engine.processCalls, 1);
      expect(acks, ['a']);
      final stored = await store.lookupByEnvelopeId('a');
      expect(stored!.plaintext, 'hi');
      expect(stored.mlsPhase, LocalMlsPhase.committed);
      expect(stored.delivery, LocalMessageDelivery.received);
    });

    test('a new controller restores stored history without decrypting again', () async {
      final store = await _openHistory(tempDir);
      addTearDown(store.close);
      final engine = _ScriptedMls();
      final service = _service(engine, history: store);
      service.bindConversationPeer(_conv, _peer);
      service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
      await service.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [_env('a', 4, MlsContentTypes.application)],
      );

      final first = await _controller(service);
      addTearDown(first.dispose);
      first.controller.conversationId = _conv;
      await first.controller.restoreLocalHistory();
      expect(first.controller.messages, hasLength(1));
      expect(first.controller.messages.single.plaintext, 'hi');
      expect(
        first.controller.messages.single.delivery,
        ChatDeliveryState.received,
      );

      final second = await _controller(service);
      addTearDown(second.dispose);
      second.controller.conversationId = _conv;
      await second.controller.restoreLocalHistory();
      expect(second.controller.messages, hasLength(1));
      expect(second.controller.messages.single.plaintext, 'hi');
      expect(engine.inspectCalls, 1);
      expect(engine.processCalls, 1);
    });

    test('a duplicate pending envelope is not shown twice', () async {
      final store = await _openHistory(tempDir);
      addTearDown(store.close);
      final acks = <String>[];
      final engine = _ScriptedMls();
      final service = _service(engine, acks: acks, history: store);
      service.bindConversationPeer(_conv, _peer);
      service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
      final envelope = _env('a', 4, MlsContentTypes.application);
      await service.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [envelope],
      );
      final restarted = _service(engine, acks: acks, history: store);
      restarted.bindConversationPeer(_conv, _peer);
      restarted.rememberGroup(_conv, 'abc');
      restarted.bindConversationPeer(_conv, _peer);
      final again = await restarted.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [envelope],
      );
      expect(again, hasLength(1));
      expect(engine.inspectCalls, 1);
      expect(engine.processCalls, 1);
      expect(acks, ['a', 'a']);

      final controller = await _controller(service);
      addTearDown(controller.dispose);
      controller.controller.conversationId = _conv;
      await controller.controller.restoreLocalHistory();
      expect(controller.controller.messages, hasLength(1));
      expect(controller.controller.messages.single.plaintext, 'hi');
    });

    test('an inspected row is processed again and then acknowledged', () async {
      final store = await _openHistory(tempDir);
      addTearDown(store.close);
      final engine = _ScriptedMls(processError: _SecretLeak());
      final firstAcks = <String>[];
      final first = _service(engine, acks: firstAcks, history: store);
      first.bindConversationPeer(_conv, _peer);
      first.rememberGroup(_conv, 'abc');
      first.bindConversationPeer(_conv, _peer);
      final envelope = _env('a', 4, MlsContentTypes.application);
      final failed = await first.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [envelope],
      );
      expect(failed, isEmpty);
      expect(firstAcks, isEmpty);
      expect(engine.inspectCalls, 1);
      expect(engine.processCalls, 1);
      expect((await store.lookupByEnvelopeId('a'))!.mlsPhase, LocalMlsPhase.inspected);

      engine.processError = null;
      final secondAcks = <String>[];
      final second = _service(engine, acks: secondAcks, history: store);
      second.bindConversationPeer(_conv, _peer);
      second.rememberGroup(_conv, 'abc');
      second.bindConversationPeer(_conv, _peer);
      final retried = await second.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [envelope],
      );
      expect(retried.single.plaintext, 'hi');
      expect(secondAcks, ['a']);
      expect(engine.inspectCalls, 1);
      expect(engine.processCalls, 2);
      expect(
        (await store.lookupByEnvelopeId('a'))!.mlsPhase,
        LocalMlsPhase.committed,
      );
    });

    test('an uncertain process retry is not acknowledged', () async {
      final store = await _openHistory(tempDir);
      addTearDown(store.close);
      final engine = _ScriptedMls();
      final first = _service(engine, history: _FailOnCommit(store));
      first.bindConversationPeer(_conv, _peer);
      first.rememberGroup(_conv, 'abc');
      first.bindConversationPeer(_conv, _peer);
      final envelope = _env('a', 4, MlsContentTypes.application);
      final interrupted = await first.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [envelope],
      );
      expect(interrupted, isEmpty);
      expect(engine.processCalls, 1);
      final saved = await store.lookupByEnvelopeId('a');
      expect(saved!.plaintext, 'hi');
      expect(saved.mlsPhase, LocalMlsPhase.inspected);

      engine.processError = _ReuseLeak();
      final acks = <String>[];
      final second = _service(engine, acks: acks, history: store);
      second.bindConversationPeer(_conv, _peer);
      second.rememberGroup(_conv, 'abc');
      second.bindConversationPeer(_conv, _peer);
      final retried = await second.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [envelope],
      );
      expect(retried, isEmpty);
      expect(acks, isEmpty);
      expect(engine.processCalls, 2);
      final kept = await store.lookupByEnvelopeId('a');
      expect(kept!.plaintext, 'hi');
      expect(kept.mlsPhase, LocalMlsPhase.inspected);
      expect(kept.delivery, isNot(LocalMessageDelivery.received));
    });

    test('a committed row is acknowledged without decrypting', () async {
      final store = await _openHistory(tempDir);
      addTearDown(store.close);
      final engine = _ScriptedMls();
      var rejectAck = true;
      final attempts = <String>[];
      final service = _service(
        engine,
        acks: attempts,
        history: store,
        ackStatus: () => rejectAck ? 500 : 204,
      );
      service.bindConversationPeer(_conv, _peer);
      service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
      final envelope = _env('a', 4, MlsContentTypes.application);
      final waiting = await service.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [envelope],
      );
      expect(waiting, isEmpty);
      expect(attempts, ['a']);
      expect(engine.processCalls, 1);
      expect(
        (await store.lookupByEnvelopeId('a'))!.mlsPhase,
        LocalMlsPhase.committed,
      );

      rejectAck = false;
      final acked = await service.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [envelope],
      );
      expect(acked.single.plaintext, 'hi');
      expect(attempts, ['a', 'a']);
      expect(engine.inspectCalls, 1);
      expect(engine.processCalls, 1);
      expect(
        (await store.lookupByEnvelopeId('a'))!.delivery,
        LocalMessageDelivery.received,
      );
    });

    test('failed inspection does not process or acknowledge', () async {
      final store = await _openHistory(tempDir);
      addTearDown(store.close);
      final acks = <String>[];
      final engine = _ScriptedMls(inspectError: _SecretLeak());
      final service = _service(engine, acks: acks, history: store);
      service.bindConversationPeer(_conv, _peer);
      service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
      final views = await service.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [_env('a', 4, MlsContentTypes.application)],
      );
      expect(views, isEmpty);
      expect(acks, isEmpty);
      expect(engine.inspectCalls, 1);
      expect(engine.processCalls, 0);
      expect(await store.lookupByEnvelopeId('a'), isNull);
    });

    test('a failed history write does not process or acknowledge', () async {
      final acks = <String>[];
      final engine = _ScriptedMls();
      final service = _service(engine, acks: acks, history: _InsertFails());
      service.bindConversationPeer(_conv, _peer);
      service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
      final views = await service.ingestEnvelopes(
        token: 'tok',
        myUserId: _me,
        envelopes: [_env('a', 4, MlsContentTypes.application)],
      );
      expect(views, isEmpty);
      expect(acks, isEmpty);
      expect(engine.inspectCalls, 1);
      expect(engine.processCalls, 0);
    });

    test('sending persists outgoing history as Sent', () async {
      final store = await _openHistory(tempDir);
      addTearDown(store.close);
      final engine = _ScriptedMls();
      final service = _service(engine, history: store);
      service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
      final sent = await service.sendText(
        token: 'tok',
        conversationId: _conv,
        myUserId: _me,
        plaintext: 'outgoing',
        clientMessageId: 'out-1',
      );
      expect(sent.delivery, ChatDeliveryState.sent);
      expect(engine.encryptCalls, 1);
      expect(engine.inspectCalls, 0);
      expect(engine.processCalls, 0);
      final rows = await store.listConversation(_conv);
      expect(rows, hasLength(1));
      expect(rows.single.plaintext, 'outgoing');
      expect(rows.single.delivery, LocalMessageDelivery.sent);
      expect(rows.single.senderId, _me);
      expect(rows.single.mlsPhase, isNull);
    });

    test('outgoing history survives a new controller restore', () async {
      final store = await _openHistory(tempDir);
      addTearDown(store.close);
      final engine = _ScriptedMls();
      final service = _service(engine, history: store);
      service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
      await service.sendText(
        token: 'tok',
        conversationId: _conv,
        myUserId: _me,
        plaintext: 'keep-me',
        clientMessageId: 'out-keep',
      );
      final restored = await _controller(service);
      addTearDown(restored.dispose);
      restored.controller.conversationId = _conv;
      await restored.controller.restoreLocalHistory();
      expect(restored.controller.messages, hasLength(1));
      expect(restored.controller.messages.single.plaintext, 'keep-me');
      expect(restored.controller.messages.single.isMine, isTrue);
      expect(
        restored.controller.messages.single.delivery,
        ChatDeliveryState.sent,
      );
    });

    test('local store failure does not claim Sent', () async {
      final engine = _ScriptedMls();
      final service = _service(engine, history: _InsertFails());
      service.rememberGroup(_conv, 'abc');
      service.bindConversationPeer(_conv, _peer);
      final failed = await service.sendText(
        token: 'tok',
        conversationId: _conv,
        myUserId: _me,
        plaintext: 'blocked',
        clientMessageId: 'out-fail-store',
      );
      expect(failed.delivery, ChatDeliveryState.failed);
      expect(engine.encryptCalls, 0);
    });

    test('HTTP send failure keeps Failed in local history', () async {
      final store = await _openHistory(tempDir);
      addTearDown(store.close);
      final engine = _ScriptedMls();
      final service = EncryptedConversationService(
        api: ApiClient(
          client: MockClient((request) async {
            if (request.method == 'POST' &&
                request.url.path.endsWith('/envelopes')) {
              return http.Response('no', 500);
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
        ..bindConversationPeer(_conv, _peer);
      final failed = await service.sendText(
        token: 'tok',
        conversationId: _conv,
        myUserId: _me,
        plaintext: 'retry-later',
        clientMessageId: 'out-http-fail',
      );
      expect(failed.delivery, ChatDeliveryState.failed);
      final row = (await store.listConversation(_conv)).single;
      expect(row.delivery, LocalMessageDelivery.failed);
      expect(row.plaintext, 'retry-later');
    });
  });
}

MlsDiagnosticEvent _event(String stage) {
  return MlsDiagnostics.events.singleWhere((event) => event.stage == stage);
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 30; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition was not reached');
}

class _Harness {
  _Harness(this.controller, this.auth, this.service, this._posts);
  final ConversationController controller;
  final AuthController auth;
  final EncryptedConversationService service;
  final int Function() _posts;
  int get posts => _posts();
  var _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.dispose();
    auth.dispose();
  }
}

Future<_Harness> _harness({
  required _ScriptedMls engine,
  int failPosts = 0,
}) async {
  var remainingFailures = failPosts;
  var posts = 0;
  final api = ApiClient(
    client: MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/envelopes')) {
        posts++;
        if (remainingFailures > 0) {
          remainingFailures--;
          return http.Response('SECRET-BODY', 500);
        }
        return http.Response(jsonEncode(_sentJson()), 201);
      }
      return http.Response('no', 404);
    }),
    baseUri: Uri.parse('http://example.test'),
  );
  final auth = AuthController(
    store: _FakeSessionStore(),
    validate: (_) async => AuthIdentity(
      userId: _me,
      deviceId: _device,
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    ),
    revoke: (_) async {},
  );
  final service = EncryptedConversationService(
    api: api,
    mls: MlsSessionManager(),
    engine: engine,
    history: _MemoryHistory(),
  )
        ..rememberGroup(_conv, 'abc')
        ..bindConversationPeer(_conv, _peer);
  final controller = ConversationController(
    api: api,
    auth: auth,
    mls: MlsSessionManager(),
    peerUserId: _peer,
    peerEmail: 'peer@example.com',
    service: service,
  );
  await auth.signIn(
    AuthSession(
      userId: _me,
      deviceId: _device,
      token: 'session-token',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    ),
  );
  controller.conversationId = _conv;
  return _Harness(controller, auth, service, () => posts);
}

EncryptedConversationService _service(
  _ScriptedMls engine, {
  List<String>? acks,
  InboundMessageHistory? history,
  int Function()? ackStatus,
}) {
  return EncryptedConversationService(
    api: ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/ack')) {
          final parts = request.url.path.split('/');
          acks?.add(parts[parts.length - 2]);
          return http.Response('', ackStatus?.call() ?? 204);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/envelopes')) {
          return http.Response(jsonEncode(_sentJson()), 201);
        }
        return http.Response('no', 404);
      }),
      baseUri: Uri.parse('http://example.test'),
    ),
    mls: MlsSessionManager(),
    engine: engine,
    history: history ?? _MemoryHistory(),
  );
}

Future<LocalMessageStore> _openHistory(Directory dir) {
  return LocalMessageStore.open(
    userId: _me,
    deviceId: _device,
    dbPath: '${dir.path}${Platform.pathSeparator}messages.db',
    storage: const FlutterSecureStorage(),
    factory: databaseFactoryFfi,
  );
}

Future<({ConversationController controller, void Function() dispose})>
    _controller(EncryptedConversationService service) async {
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
      token: 'session-token',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    ),
  );
  final controller = ConversationController(
    api: service.api,
    auth: auth,
    mls: MlsSessionManager(),
    peerUserId: _peer,
    peerEmail: 'peer@example.com',
    service: service,
  );
  return (
    controller: controller,
    dispose: () {
      controller.dispose();
      auth.dispose();
    },
  );
}

class _ReuseLeak implements Exception {
  @override
  String toString() => 'SecretReuseError: generation consumed';
}

class _MemoryHistory implements InboundMessageHistory {
  final List<LocalMessageRecord> _rows = [];

  @override
  Future<LocalMessageRecord?> lookupByClientMessageId({
    required String conversationId,
    required String clientMessageId,
  }) async {
    for (final row in _rows) {
      if (row.conversationId == conversationId &&
          row.clientMessageId == clientMessageId) {
        return row;
      }
    }
    return null;
  }

  @override
  Future<LocalMessageRecord?> lookupByEnvelopeId(String envelopeId) async {
    for (final row in _rows) {
      if (row.envelopeId == envelopeId) return row;
    }
    return null;
  }

  @override
  Future<List<LocalMessageRecord>> listConversation(
    String conversationId,
  ) async {
    return _rows
        .where((row) => row.conversationId == conversationId)
        .toList(growable: false);
  }

  @override
  Future<LocalMessageRecord> insert(LocalMessageDraft draft) async {
    final record = LocalMessageRecord(
      ownerUserId: _me,
      ownerDeviceId: _device,
      conversationId: draft.conversationId,
      senderId: draft.senderId,
      clientMessageId: draft.clientMessageId,
      envelopeId: draft.envelopeId,
      conversationSeq: draft.conversationSeq,
      createdAtRaw: draft.createdAt.toUtc().toIso8601String(),
      delivery: draft.delivery,
      mlsPhase: draft.mlsPhase,
      plaintext: draft.plaintext,
      preparedCiphertext: draft.preparedCiphertext,
      mlsGroupIdHex: draft.mlsGroupIdHex,
      outboxRecipientId: draft.outboxRecipientId,
      outboxContentType: draft.outboxContentType,
    );
    _rows.add(record);
    return record;
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
  }) async {
    final index = _rows.indexWhere(
      (row) =>
          row.conversationId == conversationId &&
          row.clientMessageId == clientMessageId,
    );
    if (index < 0) throw const MessageHistoryNotFoundException();
    final current = _rows[index];
    final nextWire = identical(preparedCiphertext, keepHistoryField)
        ? current.preparedCiphertext
        : preparedCiphertext as List<int>?;
    final nextGroup = identical(mlsGroupIdHex, keepHistoryField)
        ? current.mlsGroupIdHex
        : mlsGroupIdHex as String?;
    final nextRecipient = identical(outboxRecipientId, keepHistoryField)
        ? current.outboxRecipientId
        : outboxRecipientId as String?;
    final nextContentType = identical(outboxContentType, keepHistoryField)
        ? current.outboxContentType
        : outboxContentType as String?;
    final updated = LocalMessageRecord(
      ownerUserId: current.ownerUserId,
      ownerDeviceId: current.ownerDeviceId,
      conversationId: current.conversationId,
      senderId: current.senderId,
      clientMessageId: current.clientMessageId,
      envelopeId: identical(envelopeId, keepHistoryField)
          ? current.envelopeId
          : envelopeId as String?,
      conversationSeq: identical(conversationSeq, keepHistoryField)
          ? current.conversationSeq
          : conversationSeq as int?,
      createdAtRaw: current.createdAtRaw,
      delivery: delivery ?? current.delivery,
      mlsPhase: mlsPhase ?? current.mlsPhase,
      plaintext: current.plaintext,
      preparedCiphertext: nextWire,
      mlsGroupIdHex: nextWire == null ? null : nextGroup,
      outboxRecipientId: nextWire == null ? null : nextRecipient,
      outboxContentType: nextWire == null ? null : nextContentType,
    );
    _rows[index] = updated;
    return updated;
  }
}

class _FailOnCommit implements InboundMessageHistory {
  _FailOnCommit(this.inner);

  final InboundMessageHistory inner;

  @override
  Future<LocalMessageRecord?> lookupByClientMessageId({
    required String conversationId,
    required String clientMessageId,
  }) {
    return inner.lookupByClientMessageId(
      conversationId: conversationId,
      clientMessageId: clientMessageId,
    );
  }

  @override
  Future<LocalMessageRecord?> lookupByEnvelopeId(String envelopeId) {
    return inner.lookupByEnvelopeId(envelopeId);
  }

  @override
  Future<List<LocalMessageRecord>> listConversation(String conversationId) {
    return inner.listConversation(conversationId);
  }

  @override
  Future<LocalMessageRecord> insert(LocalMessageDraft draft) {
    return inner.insert(draft);
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
    if (mlsPhase == LocalMlsPhase.committed) {
      throw StateError('commit marker failed');
    }
    return inner.markInboundState(
      conversationId: conversationId,
      clientMessageId: clientMessageId,
      mlsPhase: mlsPhase,
      delivery: delivery,
      envelopeId: envelopeId,
      conversationSeq: conversationSeq,
      preparedCiphertext: preparedCiphertext,
      mlsGroupIdHex: mlsGroupIdHex,
      outboxRecipientId: outboxRecipientId,
      outboxContentType: outboxContentType,
    );
  }
}

class _InsertFails implements InboundMessageHistory {
  @override
  Future<LocalMessageRecord?> lookupByClientMessageId({
    required String conversationId,
    required String clientMessageId,
  }) async =>
      null;

  @override
  Future<LocalMessageRecord?> lookupByEnvelopeId(String envelopeId) async =>
      null;

  @override
  Future<List<LocalMessageRecord>> listConversation(
    String conversationId,
  ) async =>
      const [];

  @override
  Future<LocalMessageRecord> insert(LocalMessageDraft draft) {
    throw StateError('history write failed');
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
    throw const MessageHistoryNotFoundException();
  }
}

MessageEnvelope _env(String id, int seq, String type, {String? sender}) {
  return MessageEnvelope(
    id: id,
    conversationId: _conv,
    senderId: sender ?? _peer,
    clientMessageId: 'client-$id',
    ciphertext: const [1],
    contentType: type,
    createdAt: DateTime.utc(2026, 1, 1),
    conversationSeq: seq,
  );
}

Map<String, Object> _sentJson() => {
      'id': 'env-1',
      'conversation_id': _conv,
      'sender_id': _me,
      'client_message_id': 'c',
      'ciphertext_b64': 'BwcH',
      'content_type': MlsContentTypes.application,
      'created_at': '2026-01-01T00:00:00.000Z',
      'conversation_seq': 9,
    };
