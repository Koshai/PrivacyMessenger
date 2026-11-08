import 'dart:convert';
import 'dart:io';

/// Maps peer user id → conversation id for chat-list previews.
///
/// Stores only opaque ids (no plaintext). Sidecar JSON next to history DB —
/// not an encrypted-history schema migration.
class ConversationPeerIndex {
  ConversationPeerIndex({required this.path});

  final String path;

  final Map<String, String> _peerToConversation = {};
  bool _loaded = false;

  static String pathBesideDatabase(String dbPath) {
    if (dbPath.toLowerCase().endsWith('.db')) {
      return '${dbPath.substring(0, dbPath.length - 3)}.peers.json';
    }
    return '$dbPath.peers.json';
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        if (key is String &&
            key.isNotEmpty &&
            value is String &&
            value.isNotEmpty) {
          _peerToConversation[key] = value;
        }
      });
    } catch (_) {
      // Corrupt index — ignore; previews fall back until chats are reopened.
    }
  }

  String? conversationIdForPeer(String peerUserId) {
    final id = peerUserId.trim();
    if (id.isEmpty) return null;
    return _peerToConversation[id];
  }

  Future<void> bind({
    required String conversationId,
    required String peerUserId,
  }) async {
    await load();
    final peer = peerUserId.trim();
    final cid = conversationId.trim();
    if (peer.isEmpty || cid.isEmpty) return;
    if (_peerToConversation[peer] == cid) return;
    _peerToConversation[peer] = cid;
    await _persist();
  }

  Future<void> _persist() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(_peerToConversation));
  }
}
