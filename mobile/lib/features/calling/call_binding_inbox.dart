import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'call_auth_session.dart';

/// One decrypted call-key binding kept on the device.
///
/// [rejected] records that the ciphertext was consumed and must not be
/// decrypted again, while still being unusable for call authentication.
class StoredCallBinding {
  const StoredCallBinding({
    required this.envelopeId,
    required this.conversationId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.signature,
    required this.statement,
    required this.storedAt,
    required this.rejected,
  });

  final String envelopeId;
  final String conversationId;
  final String senderUserId;
  final String senderDeviceId;
  final List<int> signature;
  final List<int> statement;
  final DateTime storedAt;
  final bool rejected;

  Map<String, Object?> toJson() => {
        'envelope_id': envelopeId,
        'conversation_id': conversationId,
        'sender_user_id': senderUserId,
        'sender_device_id': senderDeviceId,
        'signature_b64': base64Encode(signature),
        'statement_b64': base64Encode(statement),
        'stored_at': storedAt.toUtc().toIso8601String(),
        'rejected': rejected,
      };

  static StoredCallBinding fromJson(Map<String, dynamic> json) {
    return StoredCallBinding(
      envelopeId: json['envelope_id'] as String,
      conversationId: json['conversation_id'] as String,
      senderUserId: (json['sender_user_id'] as String).toLowerCase(),
      senderDeviceId: (json['sender_device_id'] as String).toLowerCase(),
      signature: base64Decode(json['signature_b64'] as String),
      statement: base64Decode(json['statement_b64'] as String),
      storedAt: DateTime.parse(json['stored_at'] as String).toUtc(),
      rejected: json['rejected'] as bool? ?? false,
    );
  }
}

/// Durable inbox for MLS call-key bindings.
///
/// The chat pipeline is the only writer. Call setup only reads. Records are
/// encrypted with AES-GCM before they touch the store, capped, and expired.
class CallBindingInbox {
  CallBindingInbox({
    CallAuthStore? store,
    DateTime Function()? clock,
    this.maxEntries = 8,
    this.ttl = const Duration(minutes: 3),
  })  : _store = store ?? SecureCallAuthStore(),
        _clock = clock ?? DateTime.now;

  static const payloadKey = 'call_bind_inbox_v1';
  static const keyKey = 'call_bind_inbox_key';

  final CallAuthStore _store;
  final DateTime Function() _clock;
  final int maxEntries;
  final Duration ttl;
  final AesGcm _aes = AesGcm.with256bits();

  Future<void> put(StoredCallBinding record) async {
    final now = _clock().toUtc();
    final items = await _load(now);
    items.removeWhere((e) => e.envelopeId == record.envelopeId);
    items.add(StoredCallBinding(
      envelopeId: record.envelopeId,
      conversationId: record.conversationId,
      senderUserId: record.senderUserId.toLowerCase(),
      senderDeviceId: record.senderDeviceId.toLowerCase(),
      signature: record.signature,
      statement: record.statement,
      storedAt: now,
      rejected: record.rejected,
    ));
    items.sort((a, b) => a.storedAt.compareTo(b.storedAt));
    while (items.length > maxEntries) {
      items.removeAt(0);
    }
    await _save(items);
  }

  Future<bool> contains(String envelopeId) async {
    final items = await _load(_clock().toUtc());
    return items.any((e) => e.envelopeId == envelopeId);
  }

  /// Newest usable binding for this account and device.
  Future<StoredCallBinding?> find({
    required String senderUserId,
    required String senderDeviceId,
  }) async {
    final now = _clock().toUtc();
    final items = await _load(now);
    final user = senderUserId.toLowerCase();
    final device = senderDeviceId.toLowerCase();
    StoredCallBinding? match;
    for (final item in items) {
      if (item.rejected) continue;
      if (item.senderUserId != user || item.senderDeviceId != device) continue;
      match = item;
    }
    return match;
  }

  Future<int> length() async {
    final items = await _load(_clock().toUtc());
    return items.length;
  }

  Future<void> clear() async {
    await _store.delete(payloadKey);
    await _store.delete(keyKey);
  }

  Future<List<StoredCallBinding>> _load(DateTime now) async {
    final raw = await _store.read(payloadKey);
    if (raw == null || raw.isEmpty) return [];
    final key = await _readKey();
    final parts = raw.split('.');
    if (parts.length != 3 || key == null) {
      throw StateError('Call binding inbox is corrupt');
    }
    final clear = await _aes.decrypt(
      SecretBox(
        base64Decode(parts[2]),
        nonce: base64Decode(parts[0]),
        mac: Mac(base64Decode(parts[1])),
      ),
      secretKey: SecretKey(key),
    );
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! List) throw StateError('Call binding inbox is corrupt');
    final fresh = <StoredCallBinding>[];
    var dropped = false;
    for (final item in decoded) {
      if (item is! Map) {
        dropped = true;
        continue;
      }
      final record = StoredCallBinding.fromJson(item.cast<String, dynamic>());
      if (now.difference(record.storedAt) > ttl) {
        dropped = true;
        continue;
      }
      fresh.add(record);
    }
    if (dropped) await _save(fresh);
    return fresh;
  }

  Future<void> _save(List<StoredCallBinding> items) async {
    final key = await _keyBytes();
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(items.map((e) => e.toJson()).toList())),
      secretKey: SecretKey(key),
    );
    final packed = '${base64Encode(box.nonce)}.${base64Encode(box.mac.bytes)}.${base64Encode(box.cipherText)}';
    await _store.write(payloadKey, packed);
  }

  Future<List<int>> _keyBytes() async {
    final existing = await _readKey();
    if (existing != null) return existing;
    final created = await _aes.newSecretKey();
    final bytes = await created.extractBytes();
    await _store.write(keyKey, base64Encode(bytes));
    return bytes;
  }

  Future<List<int>?> _readKey() async {
    final raw = await _store.read(keyKey);
    if (raw == null || raw.isEmpty) return null;
    final bytes = base64Decode(raw);
    if (bytes.length != 32) throw StateError('Call binding inbox key is corrupt');
    return bytes;
  }
}
