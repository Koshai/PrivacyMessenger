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
    required this.localDtls,
    required this.remoteDtls,
  });

  final CallSession session;
  final String myUserId;
  final List<int> localDtls;
  final List<int> remoteDtls;

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
