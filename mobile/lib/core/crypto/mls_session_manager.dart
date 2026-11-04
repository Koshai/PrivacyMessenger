import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../auth/auth_controller.dart';
import '../auth/auth_state.dart';
import 'device_crypto_store.dart';
import 'openmls/openmls_encryption_service.dart';
import 'protocol_messages.dart';

/// Binds authenticated session → secure crypto store → OpenMLS engine.
///
/// UI and network layers depend on this manager, not on `package:openmls`.
class MlsSessionManager {
  MlsSessionManager({
    DeviceCryptoStore? store,
  }) : _store = store ?? DeviceCryptoStore();

  final DeviceCryptoStore _store;
  DeviceCryptoSession? _session;

  PersistedDeviceCrypto? get record => _session?.record;
  OpenMlsEncryptionService? get service => _session?.service;
  bool get isReady => _session != null;

  Future<String> _dbPathFor(String userId, String deviceId) async {
    final dir = await getApplicationSupportDirectory();
    final file = File(
      '${dir.path}${Platform.pathSeparator}mls_${userId}_$deviceId.db',
    );
    return file.path;
  }

  /// Ensures identity exists for the authenticated session and opens the engine.
  Future<PersistedDeviceCrypto> ensureReady(AuthController auth) async {
    final userId = auth.state.userId;
    final deviceId = auth.state.deviceId;
    if (auth.state.status != AuthStatus.authenticated ||
        userId == null ||
        deviceId == null) {
      throw StateError('Not authenticated');
    }

    final existing = _session;
    if (existing != null &&
        existing.record.userId == userId &&
        existing.record.deviceId == deviceId) {
      return existing.record;
    }
    await close();

    final dbPath = await _dbPathFor(userId, deviceId);
    final hadPrior = await _store.read(userId: userId, deviceId: deviceId) != null;

    late final PersistedDeviceCrypto record;
    if (hadPrior) {
      record = await _store.loadOrCreate(
        userId: userId,
        deviceId: deviceId,
        identityLabel: userId,
        expectExisting: true,
        createIdentity: () async =>
            throw const CryptoKeyLossException('unreachable'),
        createDatabaseKey: () async =>
            throw const CryptoKeyLossException('unreachable'),
      );
    } else {
      final bootstrapKey = OpenMlsEncryptionService.generateDatabaseKey();
      final bootstrap = OpenMlsEncryptionService(
        dbPath: dbPath,
        databaseEncryptionKey: bootstrapKey,
      );
      await bootstrap.openEngine();
      try {
        record = await _store.loadOrCreate(
          userId: userId,
          deviceId: deviceId,
          identityLabel: userId,
          createIdentity: () => bootstrap.createIdentity(label: userId),
          createDatabaseKey: () async => Uint8List.fromList(bootstrapKey),
        );
      } finally {
        await bootstrap.persistAndClose();
      }
    }

    _session = await DeviceCryptoSession.open(record: record, dbPath: dbPath);
    return record;
  }

  Future<KeyPackageRecord> createKeyPackage() async {
    final svc = service;
    if (svc == null) throw StateError('MLS session not ready');
    return svc.createKeyPackage();
  }

  Future<void> clearOnLogout({
    required String userId,
    required String deviceId,
  }) async {
    await close();
    await _store.clearOnLogout(userId: userId, deviceId: deviceId);
  }

  Future<void> close() async {
    await _session?.close();
    _session = null;
  }
}
