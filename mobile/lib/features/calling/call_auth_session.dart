import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'call_auth.dart';
import 'calling_api_client.dart';

/// Runs the hello/confirm handshake for one peer connection.
class CallAuthSession {
  CallAuthSession({
    required this.api,
    required this.token,
    required this.userId,
    required this.deviceId,
    required this.localMlsFingerprintHex,
    this.peerIdentities,
    FlutterSecureStorage? storage,
    this.manualTrust = const {},
  }) : _storage = storage ?? const FlutterSecureStorage(aOptions: AndroidOptions());

  final CallingApiClient api;
  final String Function() token;
  final String userId;
  final String deviceId;
  final String localMlsFingerprintHex;
  final Future<List<({String deviceId, String fingerprintHex})>> Function(String peerUserId)?
      peerIdentities;
  final FlutterSecureStorage _storage;

  /// deviceId -> user marked the safety number verified.
  final Set<String> manualTrust;

  Future<CallAuthOutcome> run(CallAuthRequest request) async {
    final pair = await _keyPair();
    final public = (await pair.extractPublicKey()).bytes;
    await api.registerCallKey(token: token(), publicKey: public);
    final mls = _hexToBytes(localMlsFingerprintHex);
    final nonce = _random(32);
    final role = request.iAmCaller ? 1 : 2;
    final hello = helloBytes(
      callId: request.session.id,
      userId: userId,
      deviceId: deviceId,
      role: role,
      nonce: nonce,
      callKey: public,
      mls: mls,
    );
    final helloSig = await Ed25519().sign(hello, keyPair: pair);
    await api.submitAuth(
      token: token(),
      callId: request.session.id,
      body: {
        'kind': 'hello',
        'client_auth_id': 'hello-$deviceId-${request.session.id}',
        'nonce_b64': base64Encode(nonce),
        'call_public_key_b64': base64Encode(public),
        'mls_fingerprint_hex': localMlsFingerprintHex,
        'dtls_local_b64': '',
        'dtls_remote_b64': '',
        'signature_b64': base64Encode(helloSig.bytes),
      },
    );

    Map<String, dynamic>? peerHello;
    for (var i = 0; i < 20; i++) {
      final frames = await api.listAuth(token: token(), callId: request.session.id);
      peerHello = frames.cast<Map<String, dynamic>?>().firstWhere(
        (f) => f?['kind'] == 'hello' && f?['sender_device_id'] != deviceId,
        orElse: () => null,
      );
      if (peerHello != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (peerHello == null) {
      return const CallAuthOutcome(phase: CallAuthPhase.failed, error: 'Peer verification timed out');
    }

    final peerKey = base64Decode(peerHello['call_public_key_b64'] as String);
    final peerMls = _hexToBytes(peerHello['mls_fingerprint_hex'] as String);
    final peerNonce = base64Decode(peerHello['nonce_b64'] as String);
    final peerDevice = peerHello['sender_device_id'] as String;
    final peerMlsHex = (peerHello['mls_fingerprint_hex'] as String).toLowerCase();
    final pinned = await _readPin(peerDevice);
    final pinnedMls = await _storage.read(key: 'call_auth_mls_$peerDevice');
    if ((pinned != null && !_eq(pinned, peerKey)) ||
        (pinnedMls != null && pinnedMls.toLowerCase() != peerMlsHex)) {
      return const CallAuthOutcome(
        phase: CallAuthPhase.identityChanged,
        error: 'Identity changed. Compare safety numbers before trusting this device.',
      );
    }
    final lookup = peerIdentities;
    if (lookup != null) {
      final peerUser =
          request.iAmCaller ? request.session.calleeUserId : request.session.callerUserId;
      final listed = await lookup(peerUser);
      final known = listed.where((e) => e.deviceId == peerDevice).toList();
      if (known.isEmpty || known.first.fingerprintHex.toLowerCase() != peerMlsHex) {
        return const CallAuthOutcome(
          phase: CallAuthPhase.identityChanged,
          error: 'Signed identity does not match the pinned messaging device.',
        );
      }
    }

    final callerNonce = request.iAmCaller ? nonce : peerNonce;
    final calleeNonce = request.iAmCaller ? peerNonce : nonce;
    final callerKey = request.iAmCaller ? public : peerKey;
    final calleeKey = request.iAmCaller ? peerKey : public;
    final callerMls = request.iAmCaller ? mls : peerMls;
    final calleeMls = request.iAmCaller ? peerMls : mls;
    final callerDtls = request.iAmCaller ? request.localDtls : request.remoteDtls;
    final calleeDtls = request.iAmCaller ? request.remoteDtls : request.localDtls;
    final transcript = CallTranscript(
      callId: request.session.id,
      callerUser: request.session.callerUserId,
      calleeUser: request.session.calleeUserId,
      callerDevice: request.session.callerDeviceId,
      calleeDevice: request.session.calleeDeviceId ?? (request.iAmCaller ? peerDevice : deviceId),
      mediaAudio: request.session.mediaType.name == 'audio',
      callerNonce: callerNonce,
      calleeNonce: calleeNonce,
      callerDtls: callerDtls,
      calleeDtls: calleeDtls,
      callerMls: callerMls,
      calleeMls: calleeMls,
      callerCallKey: callerKey,
      calleeCallKey: calleeKey,
    );
    final confirmSig = await Ed25519().sign(transcript.bytes(), keyPair: pair);
    await api.submitAuth(
      token: token(),
      callId: request.session.id,
      body: {
        'kind': 'confirm',
        'client_auth_id': 'confirm-$deviceId-${request.session.id}',
        'nonce_b64': base64Encode(nonce),
        'call_public_key_b64': base64Encode(public),
        'mls_fingerprint_hex': localMlsFingerprintHex,
        'dtls_local_b64': base64Encode(request.localDtls),
        'dtls_remote_b64': base64Encode(request.remoteDtls),
        'signature_b64': base64Encode(confirmSig.bytes),
      },
    );

    Map<String, dynamic>? peerConfirm;
    for (var i = 0; i < 20; i++) {
      final frames = await api.listAuth(token: token(), callId: request.session.id);
      peerConfirm = frames.cast<Map<String, dynamic>?>().firstWhere(
        (f) => f?['kind'] == 'confirm' && f?['sender_device_id'] == peerDevice,
        orElse: () => null,
      );
      if (peerConfirm != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (peerConfirm == null) {
      return const CallAuthOutcome(phase: CallAuthPhase.failed, error: 'Peer confirmation missing');
    }
    final phase = await verifyPeerConfirm(
      pinnedCallKey: peerKey,
      observedRemoteDtls: request.remoteDtls,
      transcript: transcript,
      peerIsCaller: !request.iAmCaller,
      signature: base64Decode(peerConfirm['signature_b64'] as String),
    );
    if (phase != CallAuthPhase.authenticated) {
      return const CallAuthOutcome(phase: CallAuthPhase.failed, error: 'Peer authentication failed');
    }
    if (pinned == null) {
      await _writePin(peerDevice, peerKey);
    }
    if (pinnedMls == null) {
      await _storage.write(key: 'call_auth_mls_$peerDevice', value: peerMlsHex);
    }
    final storedManual = await _storage.read(key: 'call_auth_manual_$peerDevice') == '1';
    return CallAuthOutcome(
      phase: CallAuthPhase.authenticated,
      fingerprintHex: peerHello['mls_fingerprint_hex'] as String?,
      peerDeviceId: peerDevice,
      manuallyVerified: manualTrust.contains(peerDevice) || storedManual,
    );
  }

  Future<SimpleKeyPair> _keyPair() async {
    final key = 'call_auth_seed_${userId}_$deviceId';
    final existing = await _storage.read(key: key);
    if (existing != null) {
      return Ed25519().newKeyPairFromSeed(base64Decode(existing));
    }
    final pair = await Ed25519().newKeyPair();
    final seed = await pair.extractPrivateKeyBytes();
    final rawSeed = seed.length == 32 ? seed : seed.sublist(0, 32);
    await _storage.write(key: key, value: base64Encode(rawSeed));
    return Ed25519().newKeyPairFromSeed(rawSeed);
  }

  Future<List<int>?> _readPin(String peerDevice) async {
    final raw = await _storage.read(key: 'call_auth_pin_$peerDevice');
    if (raw == null) return null;
    return base64Decode(raw);
  }

  Future<void> _writePin(String peerDevice, List<int> key) {
    return _storage.write(key: 'call_auth_pin_$peerDevice', value: base64Encode(key));
  }

  List<int> _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  List<int> _random(int n) {
    final rng = Random.secure();
    return List<int>.generate(n, (_) => rng.nextInt(256));
  }

  bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var v = 0;
    for (var i = 0; i < a.length; i++) {
      v |= a[i] ^ b[i];
    }
    return v == 0;
  }
}

Future<void> persistManualCallTrust(String peerDeviceId) {
  const storage = FlutterSecureStorage(aOptions: AndroidOptions());
  return storage.write(key: 'call_auth_manual_$peerDeviceId', value: '1');
}
