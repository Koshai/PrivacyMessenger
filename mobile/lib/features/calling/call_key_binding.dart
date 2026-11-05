import 'dart:typed_data';

import '../../core/crypto/mls_session_manager.dart';
import '../../core/crypto/protocol_messages.dart';
import '../../core/network/api_client.dart';
import '../messaging/encrypted_conversation_service.dart';
import 'call_auth_session.dart';
import 'call_binding_inbox.dart';

/// Publishes our call-key binding and waits for the peer binding.
///
/// Decryption happens only inside [EncryptedConversationService]. This channel
/// reads the durable inbox after that pipeline has stored the plaintext.
class MlsCallKeyChannel {
  MlsCallKeyChannel({
    required this.api,
    required this.mls,
    required this.token,
    required this.pipeline,
    required this.inbox,
    required this.myUserId,
  });

  final ApiClient api;
  final MlsSessionManager mls;
  final String Function() token;
  final String Function() myUserId;
  final EncryptedConversationService pipeline;
  final CallBindingInbox inbox;

  Future<PeerBinding?> exchange({
    required String peerUserId,
    required String peerDeviceId,
    required List<int> localStatement,
    required List<int> localSignature,
  }) async {
    final svc = mls.service;
    if (svc == null || peerDeviceId.isEmpty || myUserId().isEmpty) return null;
    final conversation = await api.openConversation(token: token(), peerUserId: peerUserId);
    final groupId = conversation.mlsGroupIdHex;
    if (groupId == null) return null;
    pipeline.rememberGroup(conversation.conversationId, groupId);
    pipeline.bindConversationPeer(conversation.conversationId, peerUserId);

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
      await pipeline.pullPending(token: token(), myUserId: myUserId());
      final stored = await inbox.find(senderUserId: peerUserId, senderDeviceId: peerDeviceId);
      if (stored != null) {
        return PeerBinding(signature: stored.signature, statement: stored.statement);
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }
}