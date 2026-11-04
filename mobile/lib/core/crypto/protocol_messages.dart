/// Opaque protocol envelopes exchanged via the server or test harness.
///
/// The Go backend must treat [bytes] as opaque ciphertext / MLS wire bytes.
/// [contentType] values are routing metadata only — never decrypted server-side.
enum MlsWireKind {
  application,
  welcome,
  commit,
  proposal,
  keyPackage,
  unknown,
}

/// MIME-like content types for opaque envelope routing (server-blind).
abstract final class MlsContentTypes {
  static const application = 'application/mls-message';
  static const welcome = 'application/mls-welcome';
  static const commit = 'application/mls-commit';
  static const proposal = 'application/mls-proposal';
  static const keyPackage = 'application/mls-key-package';
  static const opaque = 'application/opaque';

  static String forKind(MlsWireKind kind) => switch (kind) {
        MlsWireKind.application => application,
        MlsWireKind.welcome => welcome,
        MlsWireKind.commit => commit,
        MlsWireKind.proposal => proposal,
        MlsWireKind.keyPackage => keyPackage,
        MlsWireKind.unknown => opaque,
      };
}

class MlsWireMessage {
  final MlsWireKind kind;
  final List<int> bytes;
  final String? groupIdHex;
  final String? clientMessageId;

  const MlsWireMessage({
    required this.kind,
    required this.bytes,
    this.groupIdHex,
    this.clientMessageId,
  });

  /// Server-blind routing label for opaque envelopes.
  String get contentType => MlsContentTypes.forKind(kind);
}

class DeviceIdentityRecord {
  final String identityLabel;
  final List<int> publicKey;
  final List<int> signerBytes;

  const DeviceIdentityRecord({
    required this.identityLabel,
    required this.publicKey,
    required this.signerBytes,
  });
}

class KeyPackageRecord {
  final List<int> keyPackageBytes;
  final List<int> hashRef;

  const KeyPackageRecord({
    required this.keyPackageBytes,
    required this.hashRef,
  });
}

class DecryptedApplicationMessage {
  final List<int> plaintext;
  final List<int>? aad;

  const DecryptedApplicationMessage({required this.plaintext, this.aad});
}
