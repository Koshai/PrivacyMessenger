import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'openmls/openmls_encryption_service.dart';
import 'protocol_messages.dart';

/// Policies for identity lifecycle (C3/C4).
///
/// - **Logout:** wipe local MLS identity + DB key from secure storage and mark
///   state [CryptoEnrollmentState.revoked]. Encrypted MLS DB ciphertext may
///   remain on disk but is unreadable. Re-enrollment creates a **new** identity —
///   prior history cannot be decrypted. See `docs/E2EE_C3_REPORT.md` /
///   `docs/E2EE_C4_REPORT.md`.
/// - **Device replacement:** a new authenticated [deviceId] must not reuse
///   another device's stored material.
/// - **Key loss / corruption:** never silently regenerates keys.
/// - **Interrupted writes:** [CryptoEnrollmentState.enrolling] makes partial
///   persistence recoverable or fail-closed without inventing a new identity.
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

/// Explicit enrollment lifecycle states (C4).
enum CryptoEnrollmentState {
  /// No enrollment marker and no material.
  neverEnrolled,

  /// Replacement/create in progress; crash may leave incomplete material.
  enrolling,

  /// Material and marker consistent.
  active,

  /// Marker present but material missing/unreadable.
  corrupted,

  /// Explicit logout or revoke; re-enrollment must be intentional.
  revoked,
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
  static const _statePrefix = 'device_crypto_state_v1';

  /// Legacy enrollment marker from C3 (`1` means previously enrolled).
  static const _enrolledPrefix = 'device_crypto_enrolled_v1';

  final FlutterSecureStorage _storage;

  DeviceCryptoStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
            );

  String _keyFor(String userId, String deviceId) =>
      '${_storageKeyPrefix}_${userId}_$deviceId';

  String _stateKey(String userId, String deviceId) =>
      '${_statePrefix}_${userId}_$deviceId';

  String _enrolledKey(String userId, String deviceId) =>
      '${_enrolledPrefix}_${userId}_$deviceId';

  static String fingerprintOf(List<int> publicKey) =>
      sha256.convert(publicKey).toString();

  Future<CryptoEnrollmentState> enrollmentState({
    required String userId,
    required String deviceId,
  }) async {
    final stateRaw = await _storage.read(key: _stateKey(userId, deviceId));
    final material = await _readRaw(userId: userId, deviceId: deviceId);

    if (stateRaw == CryptoEnrollmentState.revoked.name) {
      return CryptoEnrollmentState.revoked;
    }
    if (stateRaw == CryptoEnrollmentState.enrolling.name) {
      if (material.record != null && material.consistent) {
        // Crash after material write but before active transition — recover.
        await _setState(
          userId: userId,
          deviceId: deviceId,
          state: CryptoEnrollmentState.active,
        );
        return CryptoEnrollmentState.active;
      }
      // Incomplete enrolling write — fail closed (do not invent new keys).
      return CryptoEnrollmentState.corrupted;
    }
    if (stateRaw == CryptoEnrollmentState.active.name ||
        stateRaw == '1' /* legacy */ ||
        await _legacyEnrolled(userId: userId, deviceId: deviceId)) {
      if (material.record != null && material.consistent) {
        return CryptoEnrollmentState.active;
      }
      return CryptoEnrollmentState.corrupted;
    }
    if (material.record != null && material.consistent) {
      // Material without state (upgrade path) — treat as active.
      await _setState(
        userId: userId,
        deviceId: deviceId,
        state: CryptoEnrollmentState.active,
      );
      return CryptoEnrollmentState.active;
    }
    if (material.corruptBlob) {
      return CryptoEnrollmentState.corrupted;
    }
    return CryptoEnrollmentState.neverEnrolled;
  }

  Future<bool> wasEverEnrolled({
    required String userId,
    required String deviceId,
  }) async {
    final state = await enrollmentState(userId: userId, deviceId: deviceId);
    return state == CryptoEnrollmentState.active ||
        state == CryptoEnrollmentState.corrupted ||
        state == CryptoEnrollmentState.enrolling ||
        state == CryptoEnrollmentState.revoked;
  }

  /// Loads existing material or creates once for this user/device binding.
  ///
  /// Never silently regenerates after [CryptoEnrollmentState.active],
  /// [CryptoEnrollmentState.corrupted], or [CryptoEnrollmentState.revoked].
  Future<PersistedDeviceCrypto> loadOrCreate({
    required String userId,
    required String deviceId,
    required String identityLabel,
    required Future<DeviceIdentityRecord> Function() createIdentity,
    required Future<Uint8List> Function() createDatabaseKey,
    bool expectExisting = false,
  }) async {
    final state = await enrollmentState(userId: userId, deviceId: deviceId);
    final existing = await read(userId: userId, deviceId: deviceId);

    if (existing != null) {
      if (existing.userId != userId || existing.deviceId != deviceId) {
        throw const DeviceIdentityMismatchException(
          'Stored crypto binding does not match authenticated session',
        );
      }
      await _assertMaterialConsistent(existing);
      await _setState(
        userId: userId,
        deviceId: deviceId,
        state: CryptoEnrollmentState.active,
      );
      return existing;
    }

    // Revoked (logout) may enroll a fresh identity on the next authenticated
    // session — that is intentional, not silent regeneration of lost keys.
    if (expectExisting ||
        state == CryptoEnrollmentState.active ||
        state == CryptoEnrollmentState.corrupted ||
        state == CryptoEnrollmentState.enrolling) {
      throw CryptoKeyLossException(
        'MLS identity missing or inconsistent (state=${state.name}); '
        'refusing silent regeneration',
      );
    }

    return _persistNewEnrollment(
      userId: userId,
      deviceId: deviceId,
      identityLabel: identityLabel,
      createIdentity: createIdentity,
      createDatabaseKey: createDatabaseKey,
    );
  }

  /// Explicit re-enrollment after key loss (user-confirmed). Safe against
  /// interrupted replacement: marks revoked, clears, then enrolling→active.
  Future<PersistedDeviceCrypto> forceReenroll({
    required String userId,
    required String deviceId,
    required String identityLabel,
    required Future<DeviceIdentityRecord> Function() createIdentity,
    required Future<Uint8List> Function() createDatabaseKey,
  }) async {
    await _setState(
      userId: userId,
      deviceId: deviceId,
      state: CryptoEnrollmentState.revoked,
    );
    await clear(userId: userId, deviceId: deviceId);
    await _storage.delete(key: _enrolledKey(userId, deviceId));
    return _persistNewEnrollment(
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
    final result = await _readRaw(userId: userId, deviceId: deviceId);
    if (result.corruptBlob) {
      await _storage.delete(key: _keyFor(userId, deviceId));
      // Keep/advance state to corrupted so loadOrCreate cannot silently regen.
      await _setState(
        userId: userId,
        deviceId: deviceId,
        state: CryptoEnrollmentState.corrupted,
      );
      return null;
    }
    return result.record;
  }

  Future<void> clear({required String userId, required String deviceId}) async {
    await _storage.delete(key: _keyFor(userId, deviceId));
  }

  /// Logout: erase crypto keys and mark revoked so a future login cannot
  /// silently recreate the same identity.
  Future<void> clearOnLogout({
    required String userId,
    required String deviceId,
  }) async {
    await clear(userId: userId, deviceId: deviceId);
    await _storage.delete(key: _enrolledKey(userId, deviceId));
    await _setState(
      userId: userId,
      deviceId: deviceId,
      state: CryptoEnrollmentState.revoked,
    );
  }

  /// Test/helper: simulate crash after marking enrolling but before material.
  Future<void> beginEnrollmentOnly({
    required String userId,
    required String deviceId,
  }) async {
    await _setState(
      userId: userId,
      deviceId: deviceId,
      state: CryptoEnrollmentState.enrolling,
    );
  }

  Future<PersistedDeviceCrypto> _persistNewEnrollment({
    required String userId,
    required String deviceId,
    required String identityLabel,
    required Future<DeviceIdentityRecord> Function() createIdentity,
    required Future<Uint8List> Function() createDatabaseKey,
  }) async {
    await _setState(
      userId: userId,
      deviceId: deviceId,
      state: CryptoEnrollmentState.enrolling,
    );

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
    await _assertMaterialConsistent(record);
    await _write(record);
    await _setState(
      userId: userId,
      deviceId: deviceId,
      state: CryptoEnrollmentState.active,
    );
    // Keep legacy marker for older readers during upgrade.
    await _storage.write(key: _enrolledKey(userId, deviceId), value: '1');
    return record;
  }

  Future<void> _assertMaterialConsistent(PersistedDeviceCrypto record) async {
    if (record.publicKey.isEmpty || record.signerBytes.isEmpty) {
      throw const CryptoKeyLossException('identity material incomplete');
    }
    if (record.databaseEncryptionKey.length != 32 ||
        record.databaseEncryptionKey.every((b) => b == 0)) {
      throw const CryptoKeyLossException('database key invalid');
    }
    if (record.fingerprintHex != fingerprintOf(record.publicKey)) {
      throw const CryptoKeyLossException('fingerprint inconsistent with public key');
    }
  }

  Future<bool> _legacyEnrolled({
    required String userId,
    required String deviceId,
  }) async {
    final marker = await _storage.read(key: _enrolledKey(userId, deviceId));
    return marker == '1';
  }

  Future<void> _setState({
    required String userId,
    required String deviceId,
    required CryptoEnrollmentState state,
  }) async {
    await _storage.write(key: _stateKey(userId, deviceId), value: state.name);
  }

  Future<({PersistedDeviceCrypto? record, bool consistent, bool corruptBlob})>
      _readRaw({
    required String userId,
    required String deviceId,
  }) async {
    final raw = await _storage.read(key: _keyFor(userId, deviceId));
    if (raw == null) {
      return (record: null, consistent: false, corruptBlob: false);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('invalid crypto blob');
      }
      final record = _fromJson(decoded);
      return (record: record, consistent: true, corruptBlob: false);
    } on FormatException {
      return (record: null, consistent: false, corruptBlob: true);
    } on ArgumentError {
      return (record: null, consistent: false, corruptBlob: true);
    } on TypeError {
      return (record: null, consistent: false, corruptBlob: true);
    } on CryptoKeyLossException {
      return (record: null, consistent: false, corruptBlob: true);
    }
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
