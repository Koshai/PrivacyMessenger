import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'models/call_session.dart';

/// Domain-separated call authentication (D4).
///
/// OpenMLS 3.3.0 does not expose a signature API. Reusing its Ed25519 MLS key
/// outside MLS would cross protocol domains, so each device holds a dedicated
/// call-authentication key. That key is registered beside the MLS identity and
/// pinned locally. A change in either key is an identity change, not a silent
/// trust update.
class CallAuthPhase {
  static const idle = 'idle';
  static const awaitingPeer = 'awaitingPeer';
  static const verifying = 'verifying';
  static const authenticated = 'authenticated';
  static const identityChanged = 'identityChanged';
  static const failed = 'failed';
}

const callHelloDomain = 'PrivacyMessenger/call-hello/v1\n';
const callConfirmDomain = 'PrivacyMessenger/call-auth/v1\n';
const callKeyBindingDomain = 'PrivacyMessenger/call-key-binding/v1\n';

enum CallAuthFailure {
  none,
  malformed,
  mismatch,
  replay,
  unexpectedKey,
  badSignature,
  unbound,
  revoked,
}

class CallCheck {
  const CallCheck(this.failure, {this.error});

  final CallAuthFailure failure;
  final String? error;

  bool get ok => failure == CallAuthFailure.none;

  String get phase => switch (failure) {
        CallAuthFailure.none => CallAuthPhase.authenticated,
        CallAuthFailure.unexpectedKey => CallAuthPhase.identityChanged,
        _ => CallAuthPhase.failed,
      };
}

class CallTranscript {
  CallTranscript({
    required this.callId,
    required this.callerUser,
    required this.calleeUser,
    required this.callerDevice,
    required this.calleeDevice,
    required this.mediaAudio,
    required this.callerNonce,
    required this.calleeNonce,
    required this.callerDtls,
    required this.calleeDtls,
    required this.callerMls,
    required this.calleeMls,
    required this.callerCallKey,
    required this.calleeCallKey,
  });

  final String callId;
  final String callerUser;
  final String calleeUser;
  final String callerDevice;
  final String calleeDevice;
  final bool mediaAudio;
  final List<int> callerNonce;
  final List<int> calleeNonce;
  final List<int> callerDtls;
  final List<int> calleeDtls;
  final List<int> callerMls;
  final List<int> calleeMls;
  final List<int> callerCallKey;
  final List<int> calleeCallKey;

  Uint8List bytes() {
    final out = BytesBuilder(copy: false);
    out.add(utf8.encode(callConfirmDomain));
    out.add([1]);
    out.add(uuidBytes(callId));
    out.add(uuidBytes(callerUser));
    out.add(uuidBytes(calleeUser));
    out.add(uuidBytes(callerDevice));
    out.add(uuidBytes(calleeDevice));
    out.add([mediaAudio ? 1 : 2]);
    out.add(_fixed(callerNonce, 32));
    out.add(_fixed(calleeNonce, 32));
    out.add(_fixed(callerDtls, 32));
    out.add(_fixed(calleeDtls, 32));
    out.add(_fixed(callerMls, 32));
    out.add(_fixed(calleeMls, 32));
    out.add(_fixed(callerCallKey, 32));
    out.add(_fixed(calleeCallKey, 32));
    return out.toBytes();
  }
}

Uint8List helloBytes({
  required String callId,
  required String userId,
  required String deviceId,
  required int role,
  required List<int> nonce,
  required List<int> callKey,
  required List<int> mls,
}) {
  final out = BytesBuilder(copy: false);
  out.add(utf8.encode(callHelloDomain));
  out.add(uuidBytes(callId));
  out.add(uuidBytes(userId));
  out.add(uuidBytes(deviceId));
  out.add([role]);
  out.add(_fixed(nonce, 32));
  out.add(_fixed(callKey, 32));
  out.add(_fixed(mls, 32));
  return out.toBytes();
}

Future<bool> verifyEd25519({
  required List<int> publicKey,
  required List<int> message,
  required List<int> signature,
}) async {
  if (publicKey.length != 32 || signature.length != 64) return false;
  return Ed25519().verify(
    message,
    signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
  );
}

/// Fail closed unless the signature matches the pinned key and the signed
/// self fingerprint matches the DTLS fingerprint observed on the peer connection.
Future<String> verifyPeerConfirm({
  required List<int> pinnedCallKey,
  required List<int> observedRemoteDtls,
  required CallTranscript transcript,
  required bool peerIsCaller,
  required List<int> signature,
}) async {
  final ok = await verifyEd25519(
    publicKey: pinnedCallKey,
    message: transcript.bytes(),
    signature: signature,
  );
  if (!ok) return CallAuthPhase.failed;
  final signedSelf = peerIsCaller ? transcript.callerDtls : transcript.calleeDtls;
  if (!_eq(signedSelf, observedRemoteDtls)) return CallAuthPhase.failed;
  return CallAuthPhase.authenticated;
}

Uint8List uuidBytes(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (hex.length != 32) {
    throw FormatException('uuid');
  }
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

List<int> _fixed(List<int> bytes, int n) {
  if (bytes.length != n) {
    throw FormatException('expected $n bytes');
  }
  return bytes;
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var v = 0;
  for (var i = 0; i < a.length; i++) {
    v |= a[i] ^ b[i];
  }
  return v == 0;
}

class CallAuthRequest {
  const CallAuthRequest({
    required this.session,
    required this.myUserId,
    this.localDtls,
    this.remoteDtls,
    this.resolveDtls,
  }) : assert(
          resolveDtls != null || (localDtls != null && remoteDtls != null),
          'DTLS fingerprints or a resolver are required',
        );

  final CallSession session;
  final String myUserId;

  /// Eager fingerprints when already known (tests / confirm-only paths).
  final List<int>? localDtls;
  final List<int>? remoteDtls;

  /// Lazy resolver so hello can be published before DTLS is read.
  /// Video devices sometimes delay description reads; blocking hello on DTLS
  /// caused peer_hello_timeout while the peer was still resolving fingerprints.
  final Future<({List<int> local, List<int> remote})> Function()? resolveDtls;

  bool get iAmCaller => session.callerUserId == myUserId;
}

class CallAuthOutcome {
  const CallAuthOutcome({
    required this.phase,
    this.fingerprintHex,
    this.peerDeviceId,
    this.manuallyVerified = false,
    this.error,
  });

  final String phase;
  final String? fingerprintHex;
  final String? peerDeviceId;
  final bool manuallyVerified;
  final String? error;
}

typedef CallAuthenticator = Future<CallAuthOutcome> Function(CallAuthRequest request);

/// Local check of a hello. The signature is verified here; a server
/// acceptance is not evidence. [pinnedCallKey] rejects a replacement key
/// even when the new key signs the frame correctly.
Future<CallCheck> verifyPeerHello({
  required String callId,
  required String userId,
  required String deviceId,
  required int role,
  required List<int> nonce,
  required List<int> callKey,
  required List<int> mls,
  required List<int> signature,
  required String expectedCallId,
  required String expectedUserId,
  required String expectedDeviceId,
  required int expectedRole,
  List<int>? pinnedCallKey,
  Set<String> seenNonces = const {},
}) async {
  if (nonce.length != 32 || callKey.length != 32 || mls.length != 32 || signature.length != 64 ||
      role != 1 && role != 2) {
    return const CallCheck(CallAuthFailure.malformed, error: 'Malformed hello');
  }
  final nonceHex = _hex(nonce);
  if (seenNonces.contains(nonceHex)) {
    return const CallCheck(CallAuthFailure.replay, error: 'Replayed hello');
  }
  Uint8List message;
  try {
    message = helloBytes(
      callId: callId,
      userId: userId,
      deviceId: deviceId,
      role: role,
      nonce: nonce,
      callKey: callKey,
      mls: mls,
    );
  } on FormatException {
    return const CallCheck(CallAuthFailure.malformed, error: 'Malformed hello');
  }
  final signed = await verifyEd25519(publicKey: callKey, message: message, signature: signature);
  if (!signed) {
    return const CallCheck(CallAuthFailure.badSignature, error: 'Hello signature rejected');
  }
  if (callId != expectedCallId ||
      userId != expectedUserId ||
      deviceId != expectedDeviceId ||
      role != expectedRole) {
    return const CallCheck(CallAuthFailure.mismatch, error: 'Hello does not match this call');
  }
  if (pinnedCallKey != null && !_eq(pinnedCallKey, callKey)) {
    return const CallCheck(
      CallAuthFailure.unexpectedKey,
      error: 'Identity changed. Compare safety numbers before trusting this device.',
    );
  }
  return const CallCheck(CallAuthFailure.none);
}

Uint8List bindingStatementBytes({
  required String userId,
  required String deviceId,
  required List<int> callKey,
  required List<int> mls,
}) {
  final out = BytesBuilder(copy: false);
  out.add(utf8.encode(callKeyBindingDomain));
  out.add([1]);
  out.add(uuidBytes(userId));
  out.add(uuidBytes(deviceId));
  out.add(_fixed(callKey, 32));
  out.add(_fixed(mls, 32));
  return out.toBytes();
}

class ParsedBindingStatement {
  const ParsedBindingStatement({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;
}

/// Returns the account and device named by a binding statement.
/// A malformed statement returns null. This does not check the signature.
ParsedBindingStatement? tryParseBindingStatement(List<int> statement) {
  final domain = utf8.encode(callKeyBindingDomain);
  const tail = 1 + 16 + 16 + 32 + 32;
  if (statement.length != domain.length + tail) return null;
  for (var i = 0; i < domain.length; i++) {
    if (statement[i] != domain[i]) return null;
  }
  var offset = domain.length;
  if (statement[offset] != 1) return null;
  offset += 1;
  try {
    final userId = _uuidFromBytes(statement.sublist(offset, offset + 16));
    offset += 16;
    final deviceId = _uuidFromBytes(statement.sublist(offset, offset + 16));
    return ParsedBindingStatement(userId: userId, deviceId: deviceId);
  } on FormatException {
    return null;
  }
}

String _uuidFromBytes(List<int> bytes) {
  if (bytes.length != 16) throw const FormatException('uuid');
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The statement must be signed by the call key and must match the hello.
/// Pins come from the local trust store. A server-reported fingerprint is not an input.
Future<CallCheck> verifyCallKeyBinding({
  required List<int> statement,
  required List<int> signature,
  required String expectedUserId,
  required String expectedDeviceId,
  required List<int> helloCallKey,
  String? pinnedMlsHex,
  List<int>? pinnedCallKey,
  String? pinnedDeviceForUser,
}) async {
  if (signature.length != 64) {
    return const CallCheck(CallAuthFailure.malformed, error: 'Malformed key binding');
  }
  if (pinnedDeviceForUser != null && pinnedDeviceForUser != expectedDeviceId) {
    return const CallCheck(
      CallAuthFailure.unexpectedKey,
      error: 'This contact is using a different device. Compare safety numbers.',
    );
  }
  final ok = await verifyEd25519(
    publicKey: helloCallKey,
    message: statement,
    signature: signature,
  );
  if (!ok) {
    return const CallCheck(CallAuthFailure.badSignature, error: 'Call-key binding rejected');
  }
  if (!_statementMatches(
    statement: statement,
    userId: expectedUserId,
    deviceId: expectedDeviceId,
    callKey: helloCallKey,
  )) {
    return const CallCheck(CallAuthFailure.unbound, error: 'Call key binding does not match the hello');
  }
  if (pinnedCallKey != null && !_eq(pinnedCallKey, helloCallKey)) {
    return const CallCheck(
      CallAuthFailure.unexpectedKey,
      error: 'Identity changed. Compare safety numbers before trusting this device.',
    );
  }
  if (pinnedMlsHex != null) {
    try {
      if (!_eq(_mlsFromStatement(statement), _hexToBytes(pinnedMlsHex))) {
        return const CallCheck(
          CallAuthFailure.unexpectedKey,
          error: 'Call key is not bound to the pinned messaging identity.',
        );
      }
    } on FormatException {
      return const CallCheck(CallAuthFailure.malformed, error: 'Malformed key binding');
    }
  }
  return const CallCheck(CallAuthFailure.none);
}

bool _statementMatches({
  required List<int> statement,
  required String userId,
  required String deviceId,
  required List<int> callKey,
}) {
  Uint8List expected;
  try {
    expected = bindingStatementBytes(
      userId: userId,
      deviceId: deviceId,
      callKey: callKey,
      mls: _mlsFromStatement(statement),
    );
  } on FormatException {
    return false;
  }
  return _eq(expected, statement);
}

List<int> _mlsFromStatement(List<int> statement) {
  if (statement.length < 32) {
    throw const FormatException('binding');
  }
  return statement.sublist(statement.length - 32);
}

List<int> _hexToBytes(String hex) {
  final clean = hex.trim().toLowerCase();
  if (clean.length != 64) throw const FormatException('fingerprint');
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int>? parseSdpFingerprint(String? sdp) {
  if (sdp == null) return null;
  final match = RegExp(r'a=fingerprint:sha-256 ([0-9A-Fa-f:]+)', caseSensitive: false).firstMatch(sdp);
  if (match == null) return null;
  final hex = match.group(1)!.replaceAll(':', '');
  if (hex.length != 64) return null;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
