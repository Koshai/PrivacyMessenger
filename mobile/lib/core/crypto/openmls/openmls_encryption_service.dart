import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

import '../encryption_service.dart';
import '../protocol_messages.dart';

/// OpenMLS-backed C1 proof-of-concept implementation.
///
/// Uses only the standard RFC 9420 ciphersuite
/// `mls128DhkemX25519Aes128GcmSha256Ed25519`.
///
/// Storage: SQLCipher (native) encrypted with a caller-provided 32-byte key.
/// Identity material is kept in memory for the PoC lifetime and must be
/// re-supplied after [restore] if the process was killed (signer bytes are
/// not written into the MLS DB by this wrapper — callers must persist them
/// separately via secure storage in later milestones).
class OpenMlsEncryptionService implements MlsGroupEncryptionService {
  static const ciphersuite =
      MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;

  final String dbPath;
  final Uint8List databaseEncryptionKey;

  MlsEngine? _engine;
  DeviceIdentityRecord? _identity;
  String? _activeGroupIdHex;
  bool _initialized = false;

  OpenMlsEncryptionService({
    required this.dbPath,
    required Uint8List databaseEncryptionKey,
  }) : databaseEncryptionKey = Uint8List.fromList(databaseEncryptionKey) {
    if (databaseEncryptionKey.length != 32) {
      throw ArgumentError(
        'databaseEncryptionKey must be 32 cryptographically random bytes',
      );
    }
    if (_isAllZero(databaseEncryptionKey)) {
      throw ArgumentError(
        'databaseEncryptionKey must not be fixed/zero-filled outside fixtures',
      );
    }
  }

  /// Generates a non-zero 32-byte key using a CSPRNG.
  static Uint8List generateDatabaseKey() {
    final rng = Random.secure();
    late Uint8List key;
    do {
      key = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    } while (_isAllZero(key));
    return key;
  }

  static bool _isAllZero(List<int> bytes) => bytes.every((b) => b == 0);

  static String _toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  MlsGroupConfig get _config =>
      MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);

  MlsEngine get _requireEngine {
    final engine = _engine;
    if (engine == null) {
      throw StateError('OpenMLS engine is not open; call restore()/init first');
    }
    return engine;
  }

  DeviceIdentityRecord get _requireIdentity {
    final identity = _identity;
    if (identity == null) {
      throw StateError('Device identity missing; createIdentity or restore it');
    }
    return identity;
  }

  @override
  bool get isAvailable => _initialized && _engine != null;

  @override
  String get backendId => 'openmls-3.3.0';

  Future<void> initializeLibrary() async {
    if (_initialized) return;
    await Openmls.init();
    _initialized = true;
  }

  Future<void> openEngine() async {
    await initializeLibrary();
    _engine ??= await MlsEngine.create(
      dbPath: dbPath,
      encryptionKey: databaseEncryptionKey,
    );
  }

  @override
  Future<void> restore() async {
    await openEngine();
  }

  /// Restores a previously created identity into this service instance.
  ///
  /// Does **not** regenerate keys after storage failure — callers must supply
  /// the persisted [identity] or fail closed.
  Future<void> adoptIdentity(DeviceIdentityRecord identity) async {
    await openEngine();
    _identity = identity;
  }

  @override
  Future<DeviceIdentityRecord> createIdentity({required String label}) async {
    await openEngine();
    if (_identity != null) {
      throw StateError('Identity already present; refusing silent regeneration');
    }

    final keyPair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
    final publicKey = keyPair.publicKey();
    final privateKey = keyPair.privateKey();
    final signerBytes = serializeSigner(
      ciphersuite: ciphersuite,
      privateKey: privateKey,
      publicKey: publicKey,
    );

    _identity = DeviceIdentityRecord(
      identityLabel: label,
      publicKey: List<int>.from(publicKey),
      signerBytes: List<int>.from(signerBytes),
    );
    return _identity!;
  }

  @override
  Future<void> ensureIdentityKeys() async {
    if (_identity == null) {
      throw StateError('No identity; call createIdentity or adoptIdentity');
    }
  }

  @override
  Future<List<int>> exportPublicIdentityKey() async {
    return List<int>.from(_requireIdentity.publicKey);
  }

  @override
  Future<KeyPackageRecord> createKeyPackage() async {
    final identity = _requireIdentity;
    final result = await _requireEngine.createKeyPackage(
      ciphersuite: ciphersuite,
      signerBytes: Uint8List.fromList(identity.signerBytes),
      credentialIdentity: Uint8List.fromList(utf8.encode(identity.identityLabel)),
      signerPublicKey: Uint8List.fromList(identity.publicKey),
    );
    final bytes = List<int>.from(result.keyPackageBytes);
    return KeyPackageRecord(
      keyPackageBytes: bytes,
      // Stable fingerprint for tests/logging only — not a protocol hash ref.
      hashRef: List<int>.from(bytes.take(16)),
    );
  }

  @override
  Future<String> createGroup() async {
    final identity = _requireIdentity;
    final result = await _requireEngine.createGroup(
      config: _config,
      signerBytes: Uint8List.fromList(identity.signerBytes),
      credentialIdentity: Uint8List.fromList(utf8.encode(identity.identityLabel)),
      signerPublicKey: Uint8List.fromList(identity.publicKey),
    );
    _activeGroupIdHex = _toHex(result.groupId);
    return _activeGroupIdHex!;
  }

  @override
  Future<({MlsWireMessage welcome, MlsWireMessage commit})> addMember({
    required String groupIdHex,
    required List<int> keyPackageBytes,
  }) async {
    final identity = _requireIdentity;
    final groupId = _fromHex(groupIdHex);
    final addResult = await _requireEngine.addMembers(
      groupIdBytes: groupId,
      signerBytes: Uint8List.fromList(identity.signerBytes),
      keyPackagesBytes: [Uint8List.fromList(keyPackageBytes)],
    );
    await _requireEngine.mergePendingCommit(groupIdBytes: groupId);

    return (
      welcome: MlsWireMessage(
        kind: MlsWireKind.welcome,
        bytes: List<int>.from(addResult.welcome),
        groupIdHex: groupIdHex,
      ),
      commit: MlsWireMessage(
        kind: MlsWireKind.commit,
        bytes: List<int>.from(addResult.commit),
        groupIdHex: groupIdHex,
      ),
    );
  }

  @override
  Future<String> joinFromWelcome({required List<int> welcomeBytes}) async {
    final identity = _requireIdentity;
    final result = await _requireEngine.joinGroupFromWelcome(
      config: _config,
      welcomeBytes: Uint8List.fromList(welcomeBytes),
      signerBytes: Uint8List.fromList(identity.signerBytes),
    );
    _activeGroupIdHex = _toHex(result.groupId);
    return _activeGroupIdHex!;
  }

  @override
  Future<MlsWireMessage> encryptApplication({
    required String groupIdHex,
    required List<int> plaintext,
    List<int>? aad,
  }) async {
    final identity = _requireIdentity;
    final encrypted = await _requireEngine.createMessage(
      groupIdBytes: _fromHex(groupIdHex),
      signerBytes: Uint8List.fromList(identity.signerBytes),
      message: Uint8List.fromList(plaintext),
      aad: aad == null ? null : Uint8List.fromList(aad),
    );
    return MlsWireMessage(
      kind: MlsWireKind.application,
      bytes: List<int>.from(encrypted.ciphertext),
      groupIdHex: groupIdHex,
    );
  }

  @override
  Future<DecryptedApplicationMessage?> processIncoming({
    required String groupIdHex,
    required List<int> messageBytes,
  }) async {
    final processed = await _requireEngine.processMessage(
      groupIdBytes: _fromHex(groupIdHex),
      messageBytes: Uint8List.fromList(messageBytes),
    );

    switch (processed.messageType) {
      case ProcessedMessageType.application:
        final app = processed.applicationMessage;
        if (app == null) {
          throw StateError('Application message missing plaintext');
        }
        return DecryptedApplicationMessage(plaintext: List<int>.from(app));
      case ProcessedMessageType.stagedCommit:
      case ProcessedMessageType.proposal:
        // Protocol state updated; no application plaintext.
        return null;
    }
  }

  @override
  Future<BigInt?> groupEpoch({required String groupIdHex}) async {
    try {
      return await _requireEngine.groupEpoch(
        groupIdBytes: _fromHex(groupIdHex),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  BigInt? messageEpoch({required List<int> messageBytes}) {
    try {
      return mlsMessageExtractEpoch(messageBytes: messageBytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<int>> encrypt({
    required String recipientUserId,
    required List<int> plaintext,
  }) async {
    final groupId = _activeGroupIdHex;
    if (groupId == null) {
      throw StateError('No active MLS group for encrypt()');
    }
    final wire = await encryptApplication(
      groupIdHex: groupId,
      plaintext: plaintext,
    );
    return wire.bytes;
  }

  @override
  Future<List<int>> decrypt({
    required String senderUserId,
    required List<int> ciphertext,
  }) async {
    final groupId = _activeGroupIdHex;
    if (groupId == null) {
      throw StateError('No active MLS group for decrypt()');
    }
    final decrypted = await processIncoming(
      groupIdHex: groupId,
      messageBytes: ciphertext,
    );
    if (decrypted == null) {
      throw StateError('Incoming message was not an application plaintext');
    }
    return decrypted.plaintext;
  }

  @override
  Future<void> persistAndClose() async {
    final engine = _engine;
    if (engine != null) {
      await engine.close();
    }
    _engine = null;
  }

  /// Reloads MLS group state from [dbPath] using the same DB key.
  ///
  /// Identity must be [adoptIdentity]'d again — we refuse to invent new keys.
  Future<void> reopenAfterRestart({required DeviceIdentityRecord identity}) async {
    await persistAndClose();
    await openEngine();
    await adoptIdentity(identity);
  }

  /// Performs a leaf self-update commit and returns the Commit wire bytes.
  Future<MlsWireMessage> selfUpdate({required String groupIdHex}) async {
    final identity = _requireIdentity;
    final result = await _requireEngine.selfUpdate(
      groupIdBytes: _fromHex(groupIdHex),
      signerBytes: Uint8List.fromList(identity.signerBytes),
    );
    return MlsWireMessage(
      kind: MlsWireKind.commit,
      bytes: List<int>.from(result.commit),
      groupIdHex: groupIdHex,
    );
  }
}
