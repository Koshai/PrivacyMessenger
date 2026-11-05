import 'dart:typed_data';

import '../../core/crypto/mls_session_manager.dart';
import '../../core/crypto/protocol_messages.dart';
import '../../core/network/api_client.dart';
import 'call_auth_session.dart';

/// Delivers the call-key binding through the existing MLS conversation.
///
/// The signaling server sees only opaque ciphertext. A binding is accepted
/// only after OpenMLS decrypts it in the established group.
class MlsCallKeyChannel {
  MlsCallKeyChannel({
    required this.api,
    required this.mls,
    required this.token,
  });

  final ApiClient api;
  final MlsSessionManager mls;
  final String Function() token;

  Future<PeerBinding?> exchange({
    required String peerUserId,
    required String peerDeviceId,
    required List<int> localStatement,
    required List<int> localSignature,
  }) async {
    final svc = mls.service;
    if (svc == null || peerDeviceId.isEmpty) return null;
    final conversation = await api.openConversation(token: token(), peerUserId: peerUserId);
    final groupId = conversation.mlsGroupIdHex;
    if (groupId == null) return null;

    final blob = BytesBuilder(copy: false)
      ..add(localSignature)
      ..add(localStatement);
    final wire = await svc.encryptApplication(groupIdHex: groupId, plaintext: blob.toBytes());
    await api.sendEnvelope(
      token: token(),
      conversationId: conversation.conversationId,
      clientMessageId: 'call-bind-${DateTime.now().microsecondsSinceEpoch}',
      ciphertext: wire.bytes,
      contentType: MlsContentTypes.callKeyBinding,
    );

    for (var i = 0; i < 20; i++) {
      final envelopes = await api.listEnvelopes(
        token: token(),
        conversationId: conversation.conversationId,
        limit: 50,
      );
      for (final env in envelopes.reversed) {
        if (env.contentType != MlsContentTypes.callKeyBinding || env.senderId != peerUserId) {
          continue;
        }
        final decrypted = await svc.processIncoming(
          groupIdHex: groupId,
          messageBytes: env.ciphertext,
        );
        final plain = decrypted?.plaintext;
        if (plain == null || plain.length <= 64) continue;
        return PeerBinding(
          signature: plain.sublist(0, 64),
          statement: plain.sublist(64),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }
}
