import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
import 'package:private_messenger/features/messaging/models/envelope.dart';

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
    this.returnNull = false,
  });

  Object? encryptError;
  Object? joinError;
  Object? processError;
  bool returnNull;
  Future<void>? encryptGate;
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
    final gate = encryptGate;
    if (gate != null) await gate;
    if (encryptError != null) throw encryptError!;
    return const MlsWireMessage(kind: MlsWireKind.application, bytes: [7, 7, 7]);
  }

  @override
  Future<String> joinFromWelcome({required List<int> welcomeBytes}) async {
    if (joinError != null) throw joinError!;
    return 'abc';
  }

  @override
  Future<DecryptedApplicationMessage?> processIncoming({
    required String groupIdHex,
    required List<int> messageBytes,
  }) async {
    if (processError != null) throw processError!;
    if (returnNull) return null;
    return const DecryptedApplicationMessage(plaintext: [104, 105]);
  }

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
    expect(message.error, 'Message could not be sent.');
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
    expect(harness.controller.messages.single.error, 'Send failed');
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
    await commitService.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [_env('c', 4, MlsContentTypes.commit)],
    );
    expect(commitAcks, isEmpty);
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

  test('a joiner still acknowledges a redundant commit without a safety warning', () async {
    final acks = <String>[];
    final engine = _ScriptedMls();
    final service = _service(engine, acks: acks);
    service.bindConversationPeer(_conv, _peer);
    await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [_env('w', 1, MlsContentTypes.welcome)],
    );
    expect(acks, ['w']);
    expect(service.keyChangeWarning, isNull);

    engine.processError = _SecretLeak();
    await service.ingestEnvelopes(
      token: 'tok',
      myUserId: _me,
      envelopes: [_env('c', 2, MlsContentTypes.commit)],
    );
    expect(acks, ['w', 'c']);
    expect(service.keyChangeWarning, isNull);
    expect(_event('commit_process').exceptionType, '_SecretLeak');
    expect(logs.join('\n'), isNot(contains(_secret)));
  });

  test('an existing safety-number warning is not replaced by a decrypt failure', () async {
    final acks = <String>[];
    final engine = _ScriptedMls(returnNull: true);
    final service = _service(engine, acks: acks);
    service.bindConversationPeer(_conv, _peer);
    service.rememberGroup(_conv, 'abc');
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
  _Harness(this.controller, this.auth, this._posts);
  final ConversationController controller;
  final AuthController auth;
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
  )..rememberGroup(_conv, 'abc');
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
  return _Harness(controller, auth, () => posts);
}

EncryptedConversationService _service(
  _ScriptedMls engine, {
  List<String>? acks,
}) {
  return EncryptedConversationService(
    api: ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/ack')) {
          final parts = request.url.path.split('/');
          acks?.add(parts[parts.length - 2]);
          return http.Response('', 204);
        }
        return http.Response('no', 404);
      }),
      baseUri: Uri.parse('http://example.test'),
    ),
    mls: MlsSessionManager(),
    engine: engine,
  );
}

MessageEnvelope _env(String id, int seq, String type) {
  return MessageEnvelope(
    id: id,
    conversationId: _conv,
    senderId: _peer,
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
