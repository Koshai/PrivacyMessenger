import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'openmls/openmls_encryption_service.dart';
import 'protocol_messages.dart';

/// Policies for identity lifecycle (C3).
///
/// - **Logout:** wipe local MLS identity + DB key from secure storage. The
///   encrypted MLS DB file may remain on disk but is unreadable without the
///   key. Message history is therefore **not** decryptable after logout until
///   an explicit re-enrollment (which creates a new identity — old ciphertext
///   cannot be read). See `docs/E2EE_C3_REPORT.md`.
/// - **Device replacement:** a new authenticated [deviceId] must not reuse
///   another device's stored material.
/// - **Key loss / corruption:** if an enrollment marker exists, missing or
///   corrupted material throws [CryptoKeyLossException] and **never** silently
///   regenerates keys.
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

/// Persisted MLS device binding (no private key material in [toString]).
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
  static const _enrolledPrefix = 'device_crypto_enrolled_v1';

  final FlutterSecureStorage _storage;

  DeviceCryptoStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
            );

  String _keyFor(String userId, String deviceId) =>
      '${_storageKeyPrefix}_${userId}_$deviceId';

  String _enrolledKey(String userId, String deviceId) =>
      '${_enrolledPrefix}_${userId}_$deviceId';

  static String fingerprintOf(List<int> publicKey) =>
      sha256.convert(publicKey).toString();

  Future<bool> wasEverEnrolled({
    required String userId,
    required String deviceId,
  }) async {
    final marker = await _storage.read(key: _enrolledKey(userId, deviceId));
    return marker == '1';
  }

  /// Loads existing material or creates once for this user/device binding.
  ///
  /// If an enrollment marker exists and material is missing/corrupt, throws
  /// [CryptoKeyLossException] instead of regenerating.
  Future<PersistedDeviceCrypto> loadOrCreate({
    required String userId,
    required String deviceId,
    required String identityLabel,
    required Future<DeviceIdentityRecord> Function() createIdentity,
    required Future<Uint8List> Function() createDatabaseKey,
    bool expectExisting = false,
  }) async {
    final enrolled = await wasEverEnrolled(userId: userId, deviceId: deviceId);
    final existing = await read(userId: userId, deviceId: deviceId);

    if (existing != null) {
      if (existing.userId != userId || existing.deviceId != deviceId) {
        throw const DeviceIdentityMismatchException(
          'Stored crypto binding does not match authenticated session',
        );
      }
      await _markEnrolled(userId: userId, deviceId: deviceId);
      return existing;
    }

    if (expectExisting || enrolled) {
      throw const CryptoKeyLossException(
        'MLS identity missing or corrupted after enrollment; '
        'refusing silent regeneration',
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
    await _markEnrolled(userId: userId, deviceId: deviceId);
    return record;
  }

  /// Explicit re-enrollment after key loss (user-confirmed). Clears markers
  /// then creates fresh material.
  Future<PersistedDeviceCrypto> forceReenroll({
    required String userId,
    required String deviceId,
    required String identityLabel,
    required Future<DeviceIdentityRecord> Function() createIdentity,
    required Future<Uint8List> Function() createDatabaseKey,
  }) async {
    await clear(userId: userId, deviceId: deviceId);
    await _storage.delete(key: _enrolledKey(userId, deviceId));
    return loadOrCreate(
      userId: userId,
      deviceId: deviceId,
      identityLabel: identityLabel,
      createIdentity: createIdentity,
      createDatabaseKey: createDatabaseKey,
    );
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
      await _storage.delete(key: _keyFor(userId, deviceId));
      // Keep enrollment marker so loadOrCreate cannot silently regenerate.
      return null;
    } on ArgumentError {
      await _storage.delete(key: _keyFor(userId, deviceId));
      return null;
    } on TypeError {
      await _storage.delete(key: _keyFor(userId, deviceId));
      return null;
    }
  }

  Future<void> clear({required String userId, required String deviceId}) async {
    await _storage.delete(key: _keyFor(userId, deviceId));
  }

  /// Logout: erase crypto keys. Enrollment marker is cleared so a future login
  /// on the same device id can enroll again only after a new auth session.
  Future<void> clearOnLogout({
    required String userId,
    required String deviceId,
  }) async {
    await clear(userId: userId, deviceId: deviceId);
    await _storage.delete(key: _enrolledKey(userId, deviceId));
  }

  Future<void> _markEnrolled({
    required String userId,
    required String deviceId,
  }) async {
    await _storage.write(key: _enrolledKey(userId, deviceId), value: '1');
  }

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
    await _storage.write(
      key: _keyFor(record.userId, record.deviceId),
      value: payload,
    );
  }

  PersistedDeviceCrypto _fromJson(Map<String, dynamic> json) {
    final publicKey = base64Decode(json['public_key_b64'] as String);
    final signer = base64Decode(json['signer_bytes_b64'] as String);
    final dbKey = base64Decode(json['db_key_b64'] as String);
    if (dbKey.length != 32 || dbKey.every((b) => b == 0)) {
      throw ArgumentError('invalid db key');
    }
    if (publicKey.isEmpty || signer.isEmpty) {
      throw ArgumentError('invalid identity material');
    }
    final userId = json['user_id'] as String;
    final deviceId = json['device_id'] as String;
    final label = json['identity_label'] as String;
    final fp = json['fingerprint_hex'] as String? ?? fingerprintOf(publicKey);
    if (fp != fingerprintOf(publicKey)) {
      throw ArgumentError('fingerprint mismatch');
    }
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
    return DeviceCryptoSession(
      record: record,
      service: service,
      dbPath: dbPath,
    );
  }

  Future<void> close() => service.persistAndClose();
}
