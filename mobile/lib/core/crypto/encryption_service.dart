import 'protocol_messages.dart';

/// Client-side encryption boundary for Milestone C+.
///
/// Messaging, persistence, and UI code must depend on this abstraction only.
/// Concrete OpenMLS types must not leak across this boundary.
abstract class EncryptionService {
  /// True when a concrete protocol implementation is wired and ready.
  bool get isAvailable;

  /// Human-readable backend id for diagnostics (never a security claim).
  String get backendId;

  Future<void> ensureIdentityKeys();

  Future<List<int>> exportPublicIdentityKey();

  /// Encrypts plaintext for an established MLS group with [groupIdHex].
  Future<List<int>> encrypt({
    required String recipientUserId,
    required List<int> plaintext,
  });

  /// Decrypts opaque ciphertext previously produced for this device/group.
  Future<List<int>> decrypt({
    required String senderUserId,
    required List<int> ciphertext,
  });
}

/// MLS-oriented operations used by the C1 proof of concept.
///
/// Production messaging should still call through [EncryptionService] where
/// possible; this interface exposes group lifecycle needed for the PoC.
abstract class MlsGroupEncryptionService implements EncryptionService {
  Future<DeviceIdentityRecord> createIdentity({required String label});

  Future<KeyPackageRecord> createKeyPackage();

  /// Creates a new MLS group owned by this device.
  Future<String> createGroup();

  /// Adds a member via key package; returns Welcome + Commit wire messages.
  Future<({MlsWireMessage welcome, MlsWireMessage commit})> addMember({
    required String groupIdHex,
    required List<int> keyPackageBytes,
  });

  Future<String> joinFromWelcome({required List<int> welcomeBytes});

  Future<MlsWireMessage> encryptApplication({
    required String groupIdHex,
    required List<int> plaintext,
    List<int>? aad,
  });

  Future<DecryptedApplicationMessage?> processIncoming({
    required String groupIdHex,
    required List<int> messageBytes,
  });

  /// Current epoch of [groupIdHex], or null when this backend cannot read it.
  Future<BigInt?> groupEpoch({required String groupIdHex});

  /// Epoch in which [messageBytes] was created, or null when it cannot be read.
  ///
  /// This is protocol metadata. Implementations must not surface the message.
  BigInt? messageEpoch({required List<int> messageBytes});

  Future<void> persistAndClose();

  Future<void> restore();
}

/// Placeholder used when no backend is configured.
class UnavailableEncryptionService implements EncryptionService {
  const UnavailableEncryptionService();

  @override
  bool get isAvailable => false;

  @override
  String get backendId => 'unavailable';

  @override
  Future<void> ensureIdentityKeys() async {
    throw UnsupportedError('Encryption backend not selected');
  }

  @override
  Future<List<int>> exportPublicIdentityKey() async {
    throw UnsupportedError('Encryption backend not selected');
  }

  @override
  Future<List<int>> encrypt({
    required String recipientUserId,
    required List<int> plaintext,
  }) async {
    throw UnsupportedError('Encryption backend not selected');
  }

  @override
  Future<List<int>> decrypt({
    required String senderUserId,
    required List<int> ciphertext,
  }) async {
    throw UnsupportedError('Encryption backend not selected');
  }
}
