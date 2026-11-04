import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';
import 'package:private_messenger/core/crypto/openmls/mls_device_harness.dart';
import 'package:private_messenger/core/crypto/openmls/openmls_encryption_service.dart';
import 'package:private_messenger/core/crypto/protocol_messages.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    await Openmls.init();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pm_openmls_c1_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('rejects zero-filled database encryption keys', () {
    expect(
      () => OpenMlsEncryptionService(
        dbPath: '${tempDir.path}${Platform.pathSeparator}zero.db',
        databaseEncryptionKey: Uint8List(32),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('identity generation and key package creation', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    addTearDown(alice.dispose);

    expect(alice.identity, isNotNull);
    expect(alice.identity!.publicKey, isNotEmpty);
    expect(alice.identity!.signerBytes, isNotEmpty);

    final package = await alice.keyPackage();
    expect(package.keyPackageBytes, isNotEmpty);
  });

  test('refuses silent identity regeneration', () async {
    final db = File('${tempDir.path}${Platform.pathSeparator}regen.db');
    final service = OpenMlsEncryptionService(
      dbPath: db.path,
      databaseEncryptionKey: OpenMlsEncryptionService.generateDatabaseKey(),
    );
    await service.openEngine();
    await service.createIdentity(label: 'alice');
    await expectLater(
      service.createIdentity(label: 'alice-again'),
      throwsA(isA<StateError>()),
    );
    await service.persistAndClose();
  });

  test('group create, welcome join, alice-to-bob and bob-to-alice', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.createGroup();
    final bobPackage = await bob.keyPackage();
    final invite = await alice.invite(bobPackage);
    expect(invite.welcome.kind, MlsWireKind.welcome);
    expect(invite.commit.kind, MlsWireKind.commit);

    await bob.join(invite.welcome);

    final fromAlice = await alice.sendText('hello bob');
    final bobSees = await bob.receiveText(fromAlice);
    expect(bobSees, 'hello bob');

    final fromBob = await bob.sendText('hello alice');
    final aliceSees = await alice.receiveText(fromBob);
    expect(aliceSees, 'hello alice');
  });

  test('rejects tampered ciphertext', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.createGroup();
    final invite = await alice.invite(await bob.keyPackage());
    await bob.join(invite.welcome);

    final wire = await alice.sendText('integrity');
    final tampered = List<int>.from(wire.bytes);
    tampered[tampered.length ~/ 2] ^= 0x5a;

    await expectLater(
      bob.service.processIncoming(
        groupIdHex: bob.groupIdHex!,
        messageBytes: tampered,
      ),
      throwsA(anything),
    );
  });

  test('unauthorized outsider cannot decrypt group traffic', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    final eve = await MlsDeviceHarness.create('eve', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(eve.dispose);

    await alice.createGroup();
    final invite = await alice.invite(await bob.keyPackage());
    await bob.join(invite.welcome);

    // Eve creates her own group — she is not a member of Alice/Bob's group.
    await eve.createGroup();

    final wire = await alice.sendText('secret');
    await expectLater(
      eve.service.processIncoming(
        groupIdHex: eve.groupIdHex!,
        messageBytes: wire.bytes,
      ),
      throwsA(anything),
    );
  });

  test('duplicate application message is rejected on second process', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.createGroup();
    final invite = await alice.invite(await bob.keyPackage());
    await bob.join(invite.welcome);

    final wire = await alice.sendText('once');
    expect(await bob.receiveText(wire), 'once');

    await expectLater(
      bob.service.processIncoming(
        groupIdHex: bob.groupIdHex!,
        messageBytes: wire.bytes,
      ),
      throwsA(anything),
    );
  });

  test('restart restores MLS state and continues messaging', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.createGroup();
    final invite = await alice.invite(await bob.keyPackage());
    await bob.join(invite.welcome);

    final before = await alice.sendText('before restart');
    expect(await bob.receiveText(before), 'before restart');

    await alice.restart();
    await bob.restart();

    final after = await alice.sendText('after restart');
    expect(await bob.receiveText(after), 'after restart');
  });

  test('epoch transition via self-update commit', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.createGroup();
    final invite = await alice.invite(await bob.keyPackage());
    await bob.join(invite.welcome);

    final update = await alice.service.selfUpdate(groupIdHex: alice.groupIdHex!);
    final processed = await bob.service.processIncoming(
      groupIdHex: bob.groupIdHex!,
      messageBytes: update.bytes,
    );
    expect(processed, isNull);

    final msg = await alice.sendText('post-epoch');
    expect(await bob.receiveText(msg), 'post-epoch');
  });

  test('stale welcome cannot be reused by a third device', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    final charlie = await MlsDeviceHarness.create('charlie', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(charlie.dispose);

    await alice.createGroup();
    final invite = await alice.invite(await bob.keyPackage());
    await bob.join(invite.welcome);

    await expectLater(
      charlie.join(invite.welcome),
      throwsA(anything),
    );
  });

  test('concurrent encrypts from both members succeed', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.createGroup();
    final invite = await alice.invite(await bob.keyPackage());
    await bob.join(invite.welcome);

    // Parallel creates across devices; deliver sequentially after.
    final results = await Future.wait([
      alice.sendText('a1'),
      bob.sendText('b1'),
    ]);
    expect(results, hasLength(2));

    expect(await bob.receiveText(results[0]), 'a1');
    expect(await alice.receiveText(results[1]), 'b1');

    final more = await Future.wait([
      alice.sendText('a2'),
      bob.sendText('b2'),
    ]);
    expect(await bob.receiveText(more[0]), 'a2');
    expect(await alice.receiveText(more[1]), 'b2');
  });

  test('out-of-order application messages decrypt within epoch window', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    final bob = await MlsDeviceHarness.create('bob', tempDir);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.createGroup();
    final invite = await alice.invite(await bob.keyPackage());
    await bob.join(invite.welcome);

    final first = await alice.sendText('first');
    final second = await alice.sendText('second');

    // Deliver second first — OpenMLS secret-tree allows out-of-order
    // generations within the configured epoch window.
    expect(await bob.receiveText(second), 'second');
    expect(await bob.receiveText(first), 'first');
  });

  test('key loss without identity prevents restore of messaging identity', () async {
    final alice = await MlsDeviceHarness.create('alice', tempDir);
    addTearDown(alice.dispose);

    await alice.createGroup();
    await alice.service.persistAndClose();

    final orphan = OpenMlsEncryptionService(
      dbPath: alice.dbFile.path,
      databaseEncryptionKey: alice.dbKey,
    );
    await orphan.openEngine();
    await expectLater(orphan.ensureIdentityKeys(), throwsStateError);
    await orphan.persistAndClose();
  });
}
