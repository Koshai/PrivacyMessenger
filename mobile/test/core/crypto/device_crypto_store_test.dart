import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/crypto/device_crypto_store.dart';
import 'package:private_messenger/core/crypto/protocol_messages.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('persists identity across store instances (restart simulation)', () async {
    final storeA = DeviceCryptoStore();
    final created = await storeA.loadOrCreate(
      userId: 'user-1',
      deviceId: 'device-1',
      identityLabel: 'user-1',
      createIdentity: () async => const DeviceIdentityRecord(
        identityLabel: 'user-1',
        publicKey: [1, 2, 3],
        signerBytes: [9, 8, 7],
      ),
      createDatabaseKey: () async => Uint8List.fromList(List.filled(32, 7)),
    );

    expect(created.fingerprintHex, isNotEmpty);
    expect(created.toString(), isNot(contains('signer')));

    // New process / new object — must restore, not regenerate.
    final storeB = DeviceCryptoStore();
    final restored = await storeB.loadOrCreate(
      userId: 'user-1',
      deviceId: 'device-1',
      identityLabel: 'user-1',
      expectExisting: true,
      createIdentity: () async => throw StateError('must not create'),
      createDatabaseKey: () async => throw StateError('must not create'),
    );

    expect(restored.publicKey, [1, 2, 3]);
    expect(restored.signerBytes, [9, 8, 7]);
    expect(restored.databaseEncryptionKey, List.filled(32, 7));
  });

  test('refuses silent regeneration when expectExisting and missing', () async {
    final store = DeviceCryptoStore();
    await expectLater(
      store.loadOrCreate(
        userId: 'u',
        deviceId: 'd',
        identityLabel: 'u',
        expectExisting: true,
        createIdentity: () async => const DeviceIdentityRecord(
          identityLabel: 'u',
          publicKey: [1],
          signerBytes: [2],
        ),
        createDatabaseKey: () async => Uint8List.fromList(List.filled(32, 1)),
      ),
      throwsA(isA<CryptoKeyLossException>()),
    );
  });

  test('clearOnLogout removes material', () async {
    final store = DeviceCryptoStore();
    await store.loadOrCreate(
      userId: 'u',
      deviceId: 'd',
      identityLabel: 'u',
      createIdentity: () async => const DeviceIdentityRecord(
        identityLabel: 'u',
        publicKey: [1],
        signerBytes: [2],
      ),
      createDatabaseKey: () async => Uint8List.fromList(List.filled(32, 3)),
    );
    await store.clearOnLogout(userId: 'u', deviceId: 'd');
    expect(await store.read(userId: 'u', deviceId: 'd'), isNull);
  });
}
