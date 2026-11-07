import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../messaging/delivery_timing.dart';
import 'call_auth.dart';
import 'calling_api_client.dart';

/// In-memory stand-in for tests. Production uses [SecureCallAuthStore].
class MemoryCallAuthStore implements CallAuthStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

abstract class CallAuthStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class IdentityPinConflict implements Exception {
  const IdentityPinConflict(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Writes [value] only when [key] is absent or already equal.
/// A different existing value is an identity change and is left untouched.
Future<void> writePinIfUnchanged(CallAuthStore store, String key, String value) async {
  final existing = await store.read(key);
  if (existing == null || existing.isEmpty) {
    await store.write(key, value);
    return;
  }
  if (existing.toLowerCase() == value.toLowerCase()) return;
  throw const IdentityPinConflict(
    'Identity changed. Compare safety numbers before trusting this device.',
  );
}

class SecureCallAuthStore implements CallAuthStore {
  SecureCallAuthStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage(aOptions: AndroidOptions());

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class PeerBinding {
  const PeerBinding({required this.statement, required this.signature});

  final List<int> statement;
  final List<int> signature;
}

/// Publishes our binding and returns the peer binding after MLS decrypt.
typedef CallKeyBindingExchange = Future<PeerBinding?> Function({
  required String peerUserId,
  required String peerDeviceId,
  required List<int> localStatement,
  required List<int> localSignature,
});

/// Runs the hello/confirm handshake for one peer connection.
class CallAuthSession {
  CallAuthSession({
    required this.api,
    required this.token,
    required this.userId,
    required this.deviceId,
    required this.localMlsFingerprintHex,
    this.bindingExchange,
    this.deviceStillEnrolled,
    CallAuthStore? store,
    this.manualTrust = const {},
  }) : _store = store ?? SecureCallAuthStore();

  final CallingApiClient api;
  final String Function() token;
  final String userId;
  final String deviceId;
  final String localMlsFingerprintHex;
  final CallKeyBindingExchange? bindingExchange;

  /// False when the peer device is revoked or no longer enrolled.
  /// This is not a fingerprint comparison.
  final Future<bool> Function(String peerUserId, String peerDeviceId)? deviceStillEnrolled;
  final CallAuthStore _store;
  final Set<String> _seenNonces = {};

  /// deviceId -> user marked the safety number verified.
  final Set<String> manualTrust;

  /// Process-local cache so video ICE-connected auth does not block on
  /// FlutterSecureStorage under camera/encoder load (device evidence: emu
  /// reached call_auth_start but never call_auth_hello_sent within the
  /// peer hello window).
  static final Map<String, SimpleKeyPair> _memoryKeyPairs = {};
  static final Map<String, Future<SimpleKeyPair>> _memoryKeyLoads = {};

  /// Prefetch the call-auth keypair before ICE Connected.
  Future<void> warmKeyPair() async {
    await _keyPair();
  }

  Future<CallAuthOutcome> run(CallAuthRequest request) async {
    DeliveryTiming.record('call_auth_keypair_begin', 0);
    final pair = await _keyPair();
    DeliveryTiming.record('call_auth_keypair_ready', 0);
    final public = (await pair.extractPublicKey()).bytes;
    await api.registerCallKey(token: token(), publicKey: public);
    DeliveryTiming.record('call_auth_key_registered', 0);
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
        // Server caps client_auth_id at 80 bytes; "confirm-" + 2 UUIDs is 81.
        'client_auth_id': authClientId(kind: 'hello', deviceId: deviceId, callId: request.session.id),
        'nonce_b64': base64Encode(nonce),
        'call_public_key_b64': base64Encode(public),
        'mls_fingerprint_hex': localMlsFingerprintHex,
        'dtls_local_b64': '',
        'dtls_remote_b64': '',
        'signature_b64': base64Encode(helloSig.bytes),
      },
    );
    DeliveryTiming.record('call_auth_hello_sent', 0);

    final exchange = bindingExchange;
    if (exchange == null) {
      return const CallAuthOutcome(
        phase: CallAuthPhase.failed,
        error: 'Call-key binding channel is not configured',
      );
    }
    final localStatement = bindingStatementBytes(
      userId: userId,
      deviceId: deviceId,
      callKey: public,
      mls: mls,
    );
    final localBindingSig = await Ed25519().sign(localStatement, keyPair: pair);

    final peerUser = request.iAmCaller ? request.session.calleeUserId : request.session.callerUserId;
    final peerDeviceExpected =
        request.iAmCaller ? request.session.calleeDeviceId : request.session.callerDeviceId;
    if (peerDeviceExpected == null || peerDeviceExpected.isEmpty) {
      return const CallAuthOutcome(phase: CallAuthPhase.failed, error: 'Peer device is not bound to this call');
    }
    final peerRole = request.iAmCaller ? 2 : 1;

    Map<String, dynamic>? peerHello;
    // Keep hello polling short relative to MLS binding wait (see MlsCallKeyChannel).
    for (var i = 0; i < 40; i++) {
      final frames = await api.listAuth(token: token(), callId: request.session.id);
      peerHello = frames.cast<Map<String, dynamic>?>().firstWhere(
        (f) => f?['kind'] == 'hello' && f?['sender_device_id'] == peerDeviceExpected,
        orElse: () => null,
      );
      if (peerHello != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (peerHello == null) {
      return const CallAuthOutcome(phase: CallAuthPhase.failed, error: 'Peer verification timed out');
    }

    final peerKey = base64Decode(peerHello['call_public_key_b64'] as String);
    final peerMlsHex = (peerHello['mls_fingerprint_hex'] as String).toLowerCase();
    final peerMls = _hexToBytes(peerMlsHex);
    final peerNonce = base64Decode(peerHello['nonce_b64'] as String);
    final peerDevice = peerHello['sender_device_id'] as String;
    final pinned = await _readPin(peerDevice);
    // Relay frames do not include role/call_id (mapAuthFrame). Role is derived
    // from the call session: treating a missing role as 0 made every hello
    // "malformed" and ended ICE-connected calls ~3s after Accept.
    final helloCheck = await verifyPeerHello(
      callId: peerHello['call_id'] as String? ?? request.session.id,
      userId: peerHello['sender_user_id'] as String? ?? '',
      deviceId: peerDevice,
      role: peerRole,
      nonce: peerNonce,
      callKey: peerKey,
      mls: peerMls,
      signature: base64Decode(peerHello['signature_b64'] as String),
      expectedCallId: request.session.id,
      expectedUserId: peerUser,
      expectedDeviceId: peerDeviceExpected,
      expectedRole: peerRole,
      pinnedCallKey: pinned,
      seenNonces: _seenNonces,
    );
    if (!helloCheck.ok) {
      return CallAuthOutcome(phase: helloCheck.phase, error: helloCheck.error, peerDeviceId: peerDevice);
    }
    _seenNonces.add(_hex(peerNonce));

    final binding = await exchange(
      peerUserId: peerUser,
      peerDeviceId: peerDeviceExpected,
      localStatement: localStatement,
      localSignature: localBindingSig.bytes,
    );
    if (binding == null) {
      return const CallAuthOutcome(
        phase: CallAuthPhase.failed,
        error: 'No MLS-authenticated call-key binding',
      );
    }
    final pinnedMls = await _store.read('call_auth_mls_$peerDevice');
    if (pinnedMls != null && pinnedMls.isNotEmpty && pinnedMls.length != 64) {
      return const CallAuthOutcome(
        phase: CallAuthPhase.failed,
        error: 'Stored messaging pin is corrupt',
      );
    }
    final pinnedUserDevice = await _store.read('call_auth_user_device_$peerUser');
    final bindingCheck = await verifyCallKeyBinding(
      statement: binding.statement,
      signature: binding.signature,
      expectedUserId: peerUser,
      expectedDeviceId: peerDeviceExpected,
      helloCallKey: peerKey,
      pinnedMlsHex: pinnedMls,
      pinnedCallKey: pinned,
      pinnedDeviceForUser: pinnedUserDevice,
    );
    if (!bindingCheck.ok) {
      return CallAuthOutcome(phase: bindingCheck.phase, error: bindingCheck.error, peerDeviceId: peerDevice);
    }
    final boundMls = binding.statement.sublist(binding.statement.length - 32);
    if (!_eq(boundMls, peerMls)) {
      return const CallAuthOutcome(
        phase: CallAuthPhase.failed,
        error: 'Hello identity does not match the MLS binding',
      );
    }
    final enrolled = deviceStillEnrolled;
    if (enrolled == null) {
      return const CallAuthOutcome(
        phase: CallAuthPhase.failed,
        error: 'Enrollment check unavailable',
      );
    }
    DeliveryTiming.record('call_auth_enrollment_check', 0);
    if (!await enrolled(peerUser, peerDeviceExpected)) {
      return const CallAuthOutcome(phase: CallAuthPhase.failed, error: 'Identity revoked');
    }

    final dtls = await _resolveDtls(request);
    DeliveryTiming.record('call_auth_dtls_ready', 0);
    final callerNonce = request.iAmCaller ? nonce : peerNonce;
    final calleeNonce = request.iAmCaller ? peerNonce : nonce;
    final callerKey = request.iAmCaller ? public : peerKey;
    final calleeKey = request.iAmCaller ? peerKey : public;
    final callerMls = request.iAmCaller ? mls : peerMls;
    final calleeMls = request.iAmCaller ? peerMls : mls;
    final callerDtls = request.iAmCaller ? dtls.local : dtls.remote;
    final calleeDtls = request.iAmCaller ? dtls.remote : dtls.local;
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
    DeliveryTiming.record('call_auth_confirm_submit', 0);
    await api.submitAuth(
      token: token(),
      callId: request.session.id,
      body: {
        'kind': 'confirm',
        'client_auth_id': authClientId(kind: 'cfm', deviceId: deviceId, callId: request.session.id),
        'nonce_b64': base64Encode(nonce),
        'call_public_key_b64': base64Encode(public),
        'mls_fingerprint_hex': localMlsFingerprintHex,
        'dtls_local_b64': base64Encode(dtls.local),
        'dtls_remote_b64': base64Encode(dtls.remote),
        'signature_b64': base64Encode(confirmSig.bytes),
      },
    );
    DeliveryTiming.record('call_auth_confirm_accepted', 0);

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
      observedRemoteDtls: dtls.remote,
      transcript: transcript,
      peerIsCaller: !request.iAmCaller,
      signature: base64Decode(peerConfirm['signature_b64'] as String),
    );
    if (phase != CallAuthPhase.authenticated) {
      return const CallAuthOutcome(phase: CallAuthPhase.failed, error: 'Peer authentication failed');
    }
    if (pinned == null) {
      await writePinIfUnchanged(_store, 'call_auth_pin_$peerDevice', base64Encode(peerKey));
    }
    if (pinnedMls == null) {
      await writePinIfUnchanged(_store, 'call_auth_mls_$peerDevice', _hex(boundMls));
    }
    if (pinnedUserDevice == null) {
      await writePinIfUnchanged(_store, 'call_auth_user_device_$peerUser', peerDevice);
    }
    final storedManual = await _store.read('call_auth_manual_$peerDevice') == '1';
    return CallAuthOutcome(
      phase: CallAuthPhase.authenticated,
      fingerprintHex: peerHello['mls_fingerprint_hex'] as String?,
      peerDeviceId: peerDevice,
      manuallyVerified: manualTrust.contains(peerDevice) || storedManual,
    );
  }

  Future<({List<int> local, List<int> remote})> _resolveDtls(CallAuthRequest request) async {
    final resolve = request.resolveDtls;
    if (resolve != null) {
      return resolve();
    }
    final local = request.localDtls;
    final remote = request.remoteDtls;
    if (local == null || remote == null) {
      throw StateError('DTLS fingerprint unavailable');
    }
    return (local: local, remote: remote);
  }

  Future<SimpleKeyPair> _keyPair() async {
    final key = 'call_auth_seed_${userId}_$deviceId';
    final cached = _memoryKeyPairs[key];
    if (cached != null) return cached;
    final inflight = _memoryKeyLoads[key];
    if (inflight != null) return inflight;
    final load = () async {
      final existing = await _store.read(key);
      late SimpleKeyPair pair;
      if (existing != null) {
        pair = await Ed25519().newKeyPairFromSeed(base64Decode(existing));
      } else {
        pair = await Ed25519().newKeyPair();
        final seed = await pair.extractPrivateKeyBytes();
        final rawSeed = seed.length == 32 ? seed : seed.sublist(0, 32);
        await _store.write(key, base64Encode(rawSeed));
        pair = await Ed25519().newKeyPairFromSeed(rawSeed);
      }
      _memoryKeyPairs[key] = pair;
      return pair;
    }();
    _memoryKeyLoads[key] = load;
    try {
      return await load;
    } finally {
      _memoryKeyLoads.remove(key);
    }
  }

  Future<List<int>?> _readPin(String peerDevice) async {
    final raw = await _store.read('call_auth_pin_$peerDevice');
    if (raw == null) return null;
    return base64Decode(raw);
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

  String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Idempotency key for call-auth frames. The server rejects ids longer than 80.
///
/// `confirm-<deviceUUID>-<callUUID>` is 81 characters and was rejected as
/// ErrInvalid (HTTP 400) after hello/binding succeeded — ending ICE-connected
/// calls during confirm submit.
String authClientId({
  required String kind,
  required String deviceId,
  required String callId,
}) {
  final id = '$kind-$deviceId-$callId';
  if (id.length > 80) {
    throw FormatException('client_auth_id exceeds 80 bytes ($kind)');
  }
  return id;
}

Future<void> persistManualCallTrust(String peerDeviceId) {
  const storage = FlutterSecureStorage(aOptions: AndroidOptions());
  return storage.write(key: 'call_auth_manual_$peerDeviceId', value: '1');
}

/// Records the messaging fingerprint pinned when a key package was claimed.
///
/// An existing different fingerprint is left in place and reported as
/// [IdentityPinConflict]. Storage errors propagate. Logout deletes only the
/// local call-signing seed; contact pins stay so a restart cannot silently
/// accept a replacement key.
Future<void> persistMessagingDevicePin(
  String deviceId,
  String fingerprintHex, {
  CallAuthStore? store,
}) async {
  final target = store ?? SecureCallAuthStore();
  final key = 'call_auth_mls_$deviceId';
  final existing = await target.read(key);
  if (existing != null && existing.isNotEmpty && existing.length != 64) {
    throw const IdentityPinConflict('Stored messaging pin is corrupt');
  }
  await writePinIfUnchanged(target, key, fingerprintHex.toLowerCase());
}

/// Removes this device's call-signing seed. Contact pins are not deleted.
Future<void> clearLocalCallSecret({
  required String userId,
  required String deviceId,
  CallAuthStore? store,
}) {
  final target = store ?? SecureCallAuthStore();
  return target.delete('call_auth_seed_${userId}_$deviceId');
}
