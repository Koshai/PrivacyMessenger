import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'openmls/openmls_encryption_service.dart';
import 'protocol_messages.dart';

/// Policies for identity lifecycle (C2).
///
/// - **Logout:** wipe local MLS identity + DB key from secure storage. The
///   MLS SQLCipher file may remain encrypted and unreadable without the key.
/// - **Device replacement:** a new authenticated [deviceId] must not reuse
///   another device's stored material — [loadOrCreate] fails closed on mismatch.
/// - **Key loss:** if secure storage is empty/corrupt, do **not** silently
///   generate a replacement identity for an existing account binding; surface
///   [CryptoKeyLossException] so the UI can require explicit re-enrollment.
class CryptoKeyLossException implements Exception {
  final String message;
  const CryptoKeyLossException(this.message);

  @override
  String toString() => 'CryptoKeyLossException: $message';
}

class DeviceIdentityMismatchException implements Exception {
  final String message;
  const DeviceIdentityMismatchException(this.message);

  @override
  String toString() => 'DeviceIdentityMismatchException: $message';
}

/// Persisted MLS device binding (no private key material in [toString]/
class PersistedDeviceCrypto {
  final String userId;
  final String deviceId;
  final String identityLabel;
  final List<int> publicKey;
  final List<int> signerBytes;
  final List<int> databaseEncryptionKey;
  final String fingerprintHex;

  const PersistedDeviceCrypto({
    required this.userId,
    required this.deviceId,
    required this.identityLabel,
    required this.publicKey,
    required this.signerBytes,
    required this.databaseEncryptionKey,
    required this.fingerprintHex,
  });

  DeviceIdentityRecord get identity => DeviceIdentityRecord(
        identityLabel: identityLabel,
        publicKey: publicKey,
        signerBytes: signerBytes,
      );

  @override
  String toString() =>
      'PersistedDeviceCrypto(userId: $userId, deviceId: $deviceId, '
      'fingerprint: $fingerprintHex)';
}

/// Production store for MLS identity + SQLCipher DB key.
class DeviceCryptoStore {
  static const _storageKeyPrefix = 'device_crypto_v1';

  final FlutterSecureStorage _storage;

  DeviceCryptoStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
            );

  String _keyFor(String userId, String deviceId) =>
      '${_storageKeyPrefix}_${userId}_$deviceId';

  static String fingerprintOf(List<int> publicKey) =>
      sha256.convert(publicKey).toString();

  /// Loads existing material or creates once for this user/device binding.
  ///
  /// Never regenerates when a record exists. Never invents keys after
  /// [expectExisting] is true (key-loss / restart path).
  Future<PersistedDeviceCrypto> loadOrCreate({
    required String userId,
    required String deviceId,
    required String identityLabel,
    required Future<DeviceIdentityRecord> Function() createIdentity,
    required Future<Uint8List> Function() createDatabaseKey,
    bool expectExisting = false,
  }) async {
    final existing = await read(userId: userId, deviceId: deviceId);
    if (existing != null) {
      if (existing.userId != userId || existing.deviceId != deviceId) {
        throw const DeviceIdentityMismatchException(
          'Stored crypto binding does not match authenticated session',
        );
      }
      return existing;
    }

    if (expectExisting) {
      throw const CryptoKeyLossException(
        'MLS identity missing after restart; refusing silent regeneration',
      );
    }

    final identity = await createIdentity();
    final dbKey = await createDatabaseKey();
    final record = PersistedDeviceCrypto(
      userId: userId,
      deviceId: deviceId,
      identityLabel: identityLabel,
      publicKey: List<int>.from(identity.publicKey),
      signerBytes: List<int>.from(identity.signerBytes),
      databaseEncryptionKey: List<int>.from(dbKey),
      fingerprintHex: fingerprintOf(identity.publicKey),
    );
    await _write(record);
    return record;
  }

  Future<PersistedDeviceCrypto?> read({
    required String userId,
    required String deviceId,
  }) async {
    final raw = await _storage.read(key: _keyFor(userId, deviceId));
    if (raw == null) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('invalid crypto blob');
      }
      return _fromJson(decoded);
    } on FormatException {
      await clear(userId: userId, deviceId: deviceId);
      return null;
    } on ArgumentError {
      await clear(userId: userId, deviceId: deviceId);
      return null;
    }
  }

  Future<void> clear({required String userId, required String deviceId}) async {
    await _storage.delete(key: _keyFor(userId, deviceId));
  }

  /// Logout policy: erase crypto for this device binding.
  Future<void> clearOnLogout({
    required String userId,
    required String deviceId,
  }) =>
      clear(userId: userId, deviceId: deviceId);

  Future<void> _write(PersistedDeviceCrypto record) async {
    final payload = jsonEncode({
      'user_id': record.userId,
      'device_id': record.deviceId,
      'identity_label': record.identityLabel,
      'public_key_b64': base64Encode(record.publicKey),
      'signer_bytes_b64': base64Encode(record.signerBytes),
      'db_key_b64': base64Encode(record.databaseEncryptionKey),
      'fingerprint_hex': record.fingerprintHex,
    });
    await _storage.write(key: _keyFor(record.userId, record.deviceId), value: payload);
  }

  PersistedDeviceCrypto _fromJson(Map<String, dynamic> json) {
    final publicKey = base64Decode(json['public_key_b64'] as String);
    final signer = base64Decode(json['signer_bytes_b64'] as String);
    final dbKey = base64Decode(json['db_key_b64'] as String);
    if (dbKey.length != 32 || dbKey.every((b) => b == 0)) {
      throw ArgumentError('invalid db key');
    }
    final userId = json['user_id'] as String;
    final deviceId = json['device_id'] as String;
    final label = json['identity_label'] as String;
    final fp = json['fingerprint_hex'] as String? ?? fingerprintOf(publicKey);
    return PersistedDeviceCrypto(
      userId: userId,
      deviceId: deviceId,
      identityLabel: label,
      publicKey: publicKey,
      signerBytes: signer,
      databaseEncryptionKey: dbKey,
      fingerprintHex: fp,
    );
  }
}

/// Opens [OpenMlsEncryptionService] bound to persisted device crypto.
class DeviceCryptoSession {
  DeviceCryptoSession({
    required this.record,
    required this.service,
    required this.dbPath,
  });

  final PersistedDeviceCrypto record;
  final OpenMlsEncryptionService service;
  final String dbPath;

  static Future<DeviceCryptoSession> open({
    required PersistedDeviceCrypto record,
    required String dbPath,
  }) async {
    final service = OpenMlsEncryptionService(
      dbPath: dbPath,
      databaseEncryptionKey: Uint8List.fromList(record.databaseEncryptionKey),
    );
    await service.openEngine();
    await service.adoptIdentity(record.identity);
    return DeviceCryptoSession(record: record, service: service, dbPath: dbPath);
  }

  Future<void> close() => service.persistAndClose();
}
