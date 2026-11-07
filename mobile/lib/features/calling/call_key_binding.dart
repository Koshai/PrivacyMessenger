import 'dart:typed_data';

import '../../core/crypto/mls_session_manager.dart';
import '../../core/crypto/protocol_messages.dart';
import '../../core/network/api_client.dart';
import '../messaging/delivery_timing.dart';
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
    this.ensureMls,
  });

  final ApiClient api;
  final MlsSessionManager mls;
  final String Function() token;
  final String Function() myUserId;
  final EncryptedConversationService pipeline;
  final CallBindingInbox inbox;

  /// Opens the OpenMLS engine if a cold start left [mls.service] null.
  /// Messaging already calls this; call auth must too after process death.
  final Future<void> Function()? ensureMls;

  /// How long we wait for the peer binding after publishing ours.
  /// Both peers start exchange near ICE Connected; 5s was too short when
  /// hello polling already consumed ~3s of the auth budget.
  static const exchangeAttempts = 40;
  static const exchangePause = Duration(milliseconds: 250);

  Future<PeerBinding?> exchange({
    required String peerUserId,
    required String peerDeviceId,
    required List<int> localStatement,
    required List<int> localSignature,
  }) async {
    final ensure = ensureMls;
    if (ensure != null) {
      await ensure();
    }
    final svc = mls.service;
    if (svc == null) {
      DeliveryTiming.record('call_binding_abort', 0, detail: 'mls_unavailable');
      return null;
    }
    if (peerDeviceId.isEmpty || myUserId().isEmpty) {
      DeliveryTiming.record('call_binding_abort', 0, detail: 'peer_or_self_empty');
      return null;
    }
    final conversation = await api.openConversation(token: token(), peerUserId: peerUserId);
    final groupId = conversation.mlsGroupIdHex;
    if (groupId == null || groupId.isEmpty) {
      DeliveryTiming.record('call_binding_abort', 0, detail: 'group_missing');
      return null;
    }
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
    DeliveryTiming.record('call_binding_published', 0);

    for (var i = 0; i < exchangeAttempts; i++) {
      await pipeline.pullPending(token: token(), myUserId: myUserId());
      final stored = await inbox.find(senderUserId: peerUserId, senderDeviceId: peerDeviceId);
      if (stored != null) {
        DeliveryTiming.record('call_binding_received', 0);
        return PeerBinding(signature: stored.signature, statement: stored.statement);
      }
      await Future<void>.delayed(exchangePause);
    }
    DeliveryTiming.record('call_binding_abort', 0, detail: 'peer_timeout');
    return null;
  }
}