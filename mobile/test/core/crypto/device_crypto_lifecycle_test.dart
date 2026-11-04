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

  Future<PersistedDeviceCrypto> enroll(DeviceCryptoStore store) {
    return store.loadOrCreate(
      userId: 'u',
      deviceId: 'd',
      identityLabel: 'u',
      createIdentity: () async => const DeviceIdentityRecord(
        identityLabel: 'u',
        publicKey: [1, 2, 3, 4],
        signerBytes: [5, 6, 7, 8],
      ),
      createDatabaseKey: () async => Uint8List.fromList(List.filled(32, 3)),
    );
  }

  test('states: neverEnrolled → active', () async {
    final store = DeviceCryptoStore();
    expect(
      await store.enrollmentState(userId: 'u', deviceId: 'd'),
      CryptoEnrollmentState.neverEnrolled,
    );
    await enroll(store);
    expect(
      await store.enrollmentState(userId: 'u', deviceId: 'd'),
      CryptoEnrollmentState.active,
    );
  });

  test('interrupted enrolling without material fails closed', () async {
    final store = DeviceCryptoStore();
    await store.beginEnrollmentOnly(userId: 'u', deviceId: 'd');
    expect(
      await store.enrollmentState(userId: 'u', deviceId: 'd'),
      CryptoEnrollmentState.corrupted,
    );
    await expectLater(
      enroll(store),
      throwsA(isA<CryptoKeyLossException>()),
    );
  });

  test('logout marks revoked; next login may enroll new identity', () async {
    final store = DeviceCryptoStore();
    final first = await enroll(store);
    await store.clearOnLogout(userId: 'u', deviceId: 'd');
    expect(
      await store.enrollmentState(userId: 'u', deviceId: 'd'),
      CryptoEnrollmentState.revoked,
    );
    final second = await store.loadOrCreate(
      userId: 'u',
      deviceId: 'd',
      identityLabel: 'u',
      createIdentity: () async => const DeviceIdentityRecord(
        identityLabel: 'u',
        publicKey: [9, 9, 9],
        signerBytes: [8, 8, 8],
      ),
      createDatabaseKey: () async => Uint8List.fromList(List.filled(32, 9)),
    );
    expect(second.publicKey, isNot(equals(first.publicKey)));
    expect(
      await store.enrollmentState(userId: 'u', deviceId: 'd'),
      CryptoEnrollmentState.active,
    );
  });

  test('forceReenroll is safe after interrupted replacement mark', () async {
    final store = DeviceCryptoStore();
    await enroll(store);
    await store.beginEnrollmentOnly(userId: 'u', deviceId: 'd');
    final replaced = await store.forceReenroll(
      userId: 'u',
      deviceId: 'd',
      identityLabel: 'u',
      createIdentity: () async => const DeviceIdentityRecord(
        identityLabel: 'u',
        publicKey: [4, 4, 4],
        signerBytes: [3, 3, 3],
      ),
      createDatabaseKey: () async => Uint8List.fromList(List.filled(32, 2)),
    );
    expect(replaced.publicKey, [4, 4, 4]);
    expect(
      await store.enrollmentState(userId: 'u', deviceId: 'd'),
      CryptoEnrollmentState.active,
    );
  });

  test('signer/db/fingerprint remain consistent', () async {
    final store = DeviceCryptoStore();
    final created = await enroll(store);
    expect(
      created.fingerprintHex,
      DeviceCryptoStore.fingerprintOf(created.publicKey),
    );
    final restored = await store.read(userId: 'u', deviceId: 'd');
    expect(restored!.signerBytes, created.signerBytes);
    expect(restored.databaseEncryptionKey, created.databaseEncryptionKey);
  });
}
