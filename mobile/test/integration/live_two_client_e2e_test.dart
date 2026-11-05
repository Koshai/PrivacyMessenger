import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openmls/openmls.dart';
import 'package:private_messenger/core/crypto/mls_session_manager.dart';
import 'package:private_messenger/core/crypto/openmls/mls_device_harness.dart';
import 'package:private_messenger/core/crypto/protocol_messages.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_auth_session.dart';
import 'package:private_messenger/features/calling/call_binding_inbox.dart';
import 'package:private_messenger/features/messaging/encrypted_conversation_service.dart';
import 'package:private_messenger/features/messaging/models/envelope.dart';

/// Live two-client native OpenMLS ↔ Go API ↔ PostgreSQL harness (C4).
///
/// Requires:
/// - `LIVE_E2E=1`
/// - `API_BASE_URL` (e.g. http://127.0.0.1:4000)
/// - `DATABASE_URL` so each run can mint isolated users/devices via `go run ./cmd/e2eseed`
///
/// A previous run revokes Alice's device. Reusing that device fails registration
/// with "identity revoked". This harness therefore seeds a new Alice/Bob pair
/// for every test and never reuses a persisted fixture file.
void main() {
  final enabled = Platform.environment['LIVE_E2E'] == '1';
  final apiBase = Platform.environment['API_BASE_URL'];
  final databaseURL = Platform.environment['DATABASE_URL'];

  if (!enabled || apiBase == null || databaseURL == null || databaseURL.isEmpty) {
    test(
      'live two-client E2E skipped (set LIVE_E2E=1, API_BASE_URL, DATABASE_URL)',
      () {},
      skip: 'Live E2E env not configured',
    );
    return;
  }

  late Directory tempDir;
  late Map<String, dynamic> fixture;
  late ApiClient api;

  setUpAll(() async {
    await Openmls.init();
    api = ApiClient(client: http.Client(), baseUri: Uri.parse(apiBase));
    expect(await api.checkHealth(), isTrue);
  });

  Future<Map<String, dynamic>> seedFreshIdentities() async {
    final backend = Directory(
      Platform.environment['E2E_BACKEND_DIR'] ?? '../backend',
    );
    if (!await backend.exists()) {
      throw StateError('backend dir not found at ${backend.path}');
    }
    final result = await Process.run(
      'go',
      ['run', './cmd/e2eseed'],
      workingDirectory: backend.path,
      environment: {
        ...Platform.environment,
        'DATABASE_URL': databaseURL,
      },
    );
    if (result.exitCode != 0) {
      throw StateError(
        'e2eseed failed (${result.exitCode}): ${result.stderr}',
      );
    }
    final raw = (result.stdout as String).trim();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('e2eseed returned unexpected JSON');
    }
    return decoded;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pm_live_e2e_');
    fixture = await seedFreshIdentities();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('native OpenMLS Alice/Bob through real API', () async {
    final aliceFx = fixture['alice'] as Map<String, dynamic>;
    final bobFx = fixture['bob'] as Map<String, dynamic>;
    final aliceToken = aliceFx['token'] as String;
    final bobToken = bobFx['token'] as String;
    final aliceUserId = aliceFx['user_id'] as String;
    final bobUserId = bobFx['user_id'] as String;
    final aliceDeviceId = aliceFx['device_id'] as String;
    final bobDeviceId = bobFx['device_id'] as String;

    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await api.registerMlsIdentity(
      token: aliceToken,
      publicKey: alice.identity!.publicKey,
    );
    await api.registerMlsIdentity(
      token: bobToken,
      publicKey: bob.identity!.publicKey,
    );

    Future<void> uploadPackages(String token, MlsDeviceHarness device) async {
      final packages = <List<int>>[];
      for (var i = 0; i < 3; i++) {
        packages.add((await device.keyPackage()).keyPackageBytes);
      }
      await api.uploadKeyPackages(token: token, packages: packages);
    }

    await uploadPackages(bobToken, bob);
    await uploadPackages(aliceToken, alice);

    final conversation = await api.openConversation(
      token: aliceToken,
      peerUserId: bobUserId,
    );
    final claimed = await api.claimKeyPackage(
      token: aliceToken,
      peerUserId: bobUserId,
    );
    final groupId = await alice.createGroup();
    final invite = await alice.invite(
      KeyPackageRecord(
        keyPackageBytes: claimed.keyPackage,
        hashRef: claimed.keyPackage.length > 16
            ? claimed.keyPackage.sublist(0, 16)
            : claimed.keyPackage,
      ),
    );
    await api.establishMlsGroup(
      token: aliceToken,
      conversationId: conversation.conversationId,
      mlsGroupIdHex: groupId,
    );
    await api.sendEnvelope(
      token: aliceToken,
      conversationId: conversation.conversationId,
      clientMessageId: 'welcome-${DateTime.now().microsecondsSinceEpoch}',
      ciphertext: invite.welcome.bytes,
      contentType: MlsContentTypes.welcome,
    );
    await api.sendEnvelope(
      token: aliceToken,
      conversationId: conversation.conversationId,
      clientMessageId: 'commit-${DateTime.now().microsecondsSinceEpoch}',
      ciphertext: invite.commit.bytes,
      contentType: MlsContentTypes.commit,
    );

    final pending1 = await api.syncPending(token: bobToken);
    expect(pending1, isNotEmpty);
    MessageEnvelope? welcome;
    MessageEnvelope? commit;
    for (final env in pending1) {
      if (env.contentType == MlsContentTypes.welcome) welcome = env;
      if (env.contentType == MlsContentTypes.commit) commit = env;
    }
    expect(welcome, isNotNull);
    expect(commit, isNotNull);
    await bob.join(
      MlsWireMessage(kind: MlsWireKind.welcome, bytes: welcome!.ciphertext),
    );
    // Welcome already advances the joiner epoch; Commit is for existing members.
    // Ack Commit without re-processing the same epoch transition.
    await api.acknowledgeEnvelope(token: bobToken, envelopeId: welcome.id);
    await api.acknowledgeEnvelope(token: bobToken, envelopeId: commit!.id);

    const secret = 'live-e2e-secret-plaintext-never-on-server';
    final fromAlice = await alice.sendText(secret);
    expect(utf8.decode(fromAlice.bytes, allowMalformed: true).contains(secret),
        isFalse);
    await api.sendEnvelope(
      token: aliceToken,
      conversationId: conversation.conversationId,
      clientMessageId: 'msg-a1-${DateTime.now().microsecondsSinceEpoch}',
      ciphertext: fromAlice.bytes,
      contentType: MlsContentTypes.application,
    );

    final bobPending = await api.syncPending(token: bobToken);
    final appEnv = bobPending.firstWhere(
      (e) => e.contentType == MlsContentTypes.application,
    );
    expect(
      await bob.receiveText(
        MlsWireMessage(kind: MlsWireKind.application, bytes: appEnv.ciphertext),
      ),
      secret,
    );
    await api.acknowledgeEnvelope(token: bobToken, envelopeId: appEnv.id);

    final fromBob = await bob.sendText('ack-from-bob');
    await api.sendEnvelope(
      token: bobToken,
      conversationId: conversation.conversationId,
      clientMessageId: 'msg-b1-${DateTime.now().microsecondsSinceEpoch}',
      ciphertext: fromBob.bytes,
      contentType: MlsContentTypes.application,
    );
    final alicePending = await api.syncPending(token: aliceToken);
    final toAlice = alicePending.firstWhere(
      (e) => e.contentType == MlsContentTypes.application,
    );
    expect(
      await alice.receiveText(
        MlsWireMessage(kind: MlsWireKind.application, bytes: toAlice.ciphertext),
      ),
      'ack-from-bob',
    );
    await api.acknowledgeEnvelope(token: aliceToken, envelopeId: toAlice.id);

    // Disconnect Bob (no WS): Alice sends, Bob syncs missed envelopes.
    final offline = await alice.sendText('offline-for-bob');
    await api.sendEnvelope(
      token: aliceToken,
      conversationId: conversation.conversationId,
      clientMessageId: 'msg-offline-${DateTime.now().microsecondsSinceEpoch}',
      ciphertext: offline.bytes,
      contentType: MlsContentTypes.application,
    );
    final missed = await api.syncPending(token: bobToken);
    expect(missed.length, 1);
    expect(
      await bob.receiveText(
        MlsWireMessage(
          kind: MlsWireKind.application,
          bytes: missed.first.ciphertext,
        ),
      ),
      'offline-for-bob',
    );
    await api.acknowledgeEnvelope(token: bobToken, envelopeId: missed.first.id);

    // Process restart with restored identity/group state.
    await alice.restart();
    await bob.restart();
    final afterRestart = await alice.sendText('after-restart');
    await api.sendEnvelope(
      token: aliceToken,
      conversationId: conversation.conversationId,
      clientMessageId: 'msg-restart-${DateTime.now().microsecondsSinceEpoch}',
      ciphertext: afterRestart.bytes,
      contentType: MlsContentTypes.application,
    );
    final restartPending = await api.syncPending(token: bobToken);
    expect(
      await bob.receiveText(
        MlsWireMessage(
          kind: MlsWireKind.application,
          bytes: restartPending.first.ciphertext,
        ),
      ),
      'after-restart',
    );
    await api.acknowledgeEnvelope(
      token: bobToken,
      envelopeId: restartPending.first.id,
    );

    // Duplicate client_message_id is idempotent.
    final dupWire = await alice.sendText('dup-check');
    final clientId = 'msg-dup-${DateTime.now().microsecondsSinceEpoch}';
    final first = await api.sendEnvelope(
      token: aliceToken,
      conversationId: conversation.conversationId,
      clientMessageId: clientId,
      ciphertext: dupWire.bytes,
      contentType: MlsContentTypes.application,
    );
    final second = await api.sendEnvelope(
      token: aliceToken,
      conversationId: conversation.conversationId,
      clientMessageId: clientId,
      ciphertext: dupWire.bytes,
      contentType: MlsContentTypes.application,
    );
    expect(second.id, first.id);

    final algo = Ed25519();
    final pair = await algo.newKeyPair();
    final callKey = (await pair.extractPublicKey()).bytes;
    final mls = List<int>.filled(32, 4);
    final statement = bindingStatementBytes(
      userId: aliceUserId,
      deviceId: aliceDeviceId,
      callKey: callKey,
      mls: mls,
    );
    final sig = await algo.sign(statement, keyPair: pair);
    final blob = <int>[...sig.bytes, ...statement];
    final bound = await alice.service.encryptApplication(
      groupIdHex: alice.groupIdHex!,
      plaintext: blob,
    );
    await api.sendEnvelope(
      token: aliceToken,
      conversationId: conversation.conversationId,
      clientMessageId: 'bind-${DateTime.now().microsecondsSinceEpoch}',
      ciphertext: bound.bytes,
      contentType: MlsContentTypes.callKeyBinding,
    );
    final bindPending = await api.syncPending(token: bobToken);
    final bindEnv = bindPending.firstWhere(
      (e) => e.contentType == MlsContentTypes.callKeyBinding,
    );
    expect(bindEnv.senderId, aliceUserId);
    final bindingStore = MemoryCallAuthStore();
    final inbox = CallBindingInbox(store: bindingStore);
    final pipeline = EncryptedConversationService(
      api: api,
      mls: MlsSessionManager(),
      inbox: inbox,
      engine: bob.service,
    );
    pipeline.rememberGroup(conversation.conversationId, bob.groupIdHex!);
    pipeline.bindConversationPeer(conversation.conversationId, aliceUserId);
    final shown = await pipeline.ingestEnvelopes(
      token: bobToken,
      myUserId: bobUserId,
      envelopes: [bindEnv],
    );
    expect(shown, isEmpty);
    final stored = await inbox.find(senderUserId: aliceUserId, senderDeviceId: aliceDeviceId);
    expect(stored, isNotNull);
    final verified = await verifyCallKeyBinding(
      statement: stored!.statement,
      signature: stored.signature,
      expectedUserId: aliceUserId,
      expectedDeviceId: aliceDeviceId,
      helloCallKey: callKey,
    );
    expect(verified.ok, isTrue);
    final wrongDevice = await verifyCallKeyBinding(
      statement: stored.statement,
      signature: stored.signature,
      expectedUserId: aliceUserId,
      expectedDeviceId: bobDeviceId,
      helloCallKey: callKey,
    );
    expect(wrongDevice.ok, isFalse);
    final duplicate = await pipeline.ingestEnvelopes(
      token: bobToken,
      myUserId: bobUserId,
      envelopes: [bindEnv],
    );
    expect(duplicate, isEmpty);
    expect(pipeline.keyChangeWarning, isNull);
    await pipeline.ingestEnvelopes(
      token: bobToken,
      myUserId: bobUserId,
      envelopes: [
        MessageEnvelope(
          id: 'substituted-binding',
          conversationId: conversation.conversationId,
          senderId: aliceUserId,
          clientMessageId: 'substituted-binding',
          ciphertext: List<int>.filled(96, 7),
          contentType: MlsContentTypes.callKeyBinding,
          createdAt: DateTime.now().toUtc(),
        ),
      ],
    );
    expect(pipeline.keyChangeWarning, isNotNull);
    expect(await inbox.find(senderUserId: aliceUserId, senderDeviceId: aliceDeviceId), isNotNull);

    final ids =
        await api.peerIdentities(token: aliceToken, peerUserId: bobUserId);
    expect(ids, isNotEmpty);
    expect(ids.first.fingerprintHex, isNotEmpty);

    // Device revoke: Alice loses crypto upload access.
    final revokeResp = await http.post(
      Uri.parse('$apiBase/crypto/device/revoke'),
      headers: {
        'Authorization': 'Bearer $aliceToken',
        'Content-Type': 'application/json',
      },
    );
    expect(revokeResp.statusCode, 204);
    await expectLater(
      api.uploadKeyPackages(
        token: aliceToken,
        packages: [
          List<int>.filled(32, 1),
        ],
      ),
      throwsA(isA<ApiException>()),
    );

    expect(aliceUserId, isNotEmpty);
    expect(aliceDeviceId, isNotEmpty);
    expect(bob.groupIdHex, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
