import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openmls/openmls.dart';
import 'package:private_messenger/core/crypto/openmls/mls_device_harness.dart';
import 'package:private_messenger/core/crypto/protocol_messages.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/messaging/models/envelope.dart';

/// Live two-client native OpenMLS ↔ Go API ↔ PostgreSQL harness (C4).
///
/// Requires:
/// - `LIVE_E2E=1`
/// - `API_BASE_URL` (e.g. http://127.0.0.1:4000)
/// - `LIVE_E2E_FIXTURE` path to JSON produced by `backend/cmd/e2eseed`
void main() {
  final enabled = Platform.environment['LIVE_E2E'] == '1';
  final apiBase = Platform.environment['API_BASE_URL'];
  final fixturePath = Platform.environment['LIVE_E2E_FIXTURE'];

  if (!enabled || apiBase == null || fixturePath == null) {
    test(
      'live two-client E2E skipped (set LIVE_E2E=1, API_BASE_URL, LIVE_E2E_FIXTURE)',
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
    fixture =
        jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>;
    api = ApiClient(client: http.Client(), baseUri: Uri.parse(apiBase));
    expect(await api.checkHealth(), isTrue);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pm_live_e2e_');
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
