import 'dart:async';
import 'dart:convert';

import '../calling/call_auth_session.dart';
import '../../core/crypto/mls_session_manager.dart';
import '../../core/crypto/protocol_messages.dart';
import '../../core/network/api_client.dart' show ApiClient, ApiException;
import 'models/envelope.dart';

/// Orchestrates MLS session setup and opaque envelope exchange.
///
/// Does not import `package:openmls` — only [MlsSessionManager].
class EncryptedConversationService {
  EncryptedConversationService({
    required this.api,
    required this.mls,
  });

  final ApiClient api;
  final MlsSessionManager mls;

  final Map<String, String> _groupByConversation = {};
  final Map<String, String> _knownFingerprints = {};
  final Map<String, String> _peerByConversation = {};
  final Set<String> _processedEnvelopeIds = {};
  final Set<String> _joinedViaWelcome = {};

  String? keyChangeWarning;

  Future<void> enrollDevice(String token) async {
    final record = mls.record;
    if (record == null) throw StateError('MLS not ready');
    await api.registerMlsIdentity(token: token, publicKey: record.publicKey);

    final packages = <List<int>>[];
    for (var i = 0; i < 5; i++) {
      final kp = await mls.createKeyPackage();
      packages.add(kp.keyPackageBytes);
    }
    await api.uploadKeyPackages(token: token, packages: packages);
  }

  Future<ConversationInfo> openWithPeer({
    required String token,
    required String myUserId,
    required String peerUserId,
  }) async {
    final conversation = await api.openConversation(
      token: token,
      peerUserId: peerUserId,
    );

    if (conversation.mlsGroupIdHex != null) {
      _groupByConversation[conversation.conversationId] =
          conversation.mlsGroupIdHex!;
      // Joiner: Welcome arrives via pending/history ingest.
      return conversation;
    }

    final svc = mls.service;
    if (svc == null) throw StateError('MLS not ready');

    try {
      final claimed =
          await api.claimKeyPackage(token: token, peerUserId: peerUserId);
      _trackFingerprint(
        peerUserId,
        claimed.fingerprintHex,
        deviceId: claimed.deviceId,
      );

      final groupId = await svc.createGroup();
      final invite = await svc.addMember(
        groupIdHex: groupId,
        keyPackageBytes: claimed.keyPackage,
      );

      final established = await api.establishMlsGroup(
        token: token,
        conversationId: conversation.conversationId,
        mlsGroupIdHex: groupId,
      );
      _groupByConversation[conversation.conversationId] = groupId;

      await api.sendEnvelope(
        token: token,
        conversationId: conversation.conversationId,
        clientMessageId: 'welcome-${DateTime.now().microsecondsSinceEpoch}',
        ciphertext: invite.welcome.bytes,
        contentType: MlsContentTypes.welcome,
      );
      await api.sendEnvelope(
        token: token,
        conversationId: conversation.conversationId,
        clientMessageId: 'commit-${DateTime.now().microsecondsSinceEpoch}',
        ciphertext: invite.commit.bytes,
        contentType: MlsContentTypes.commit,
      );
      return established;
    } on ApiException catch (e) {
      // Peer has no packages yet, or another device won the race.
      if (e.statusCode == 404 || e.statusCode == 409) {
        return conversation;
      }
      rethrow;
    }
  }

  Future<ChatMessageView> sendText({
    required String token,
    required String conversationId,
    required String myUserId,
    required String plaintext,
    required String clientMessageId,
  }) async {
    final svc = mls.service;
    if (svc == null) throw StateError('MLS not ready');
    final groupId = _groupByConversation[conversationId];
    if (groupId == null) {
      throw StateError('MLS group not ready for conversation');
    }

    final wire = await svc.encryptApplication(
      groupIdHex: groupId,
      plaintext: utf8.encode(plaintext),
    );

    final pending = ChatMessageView(
      clientMessageId: clientMessageId,
      senderId: myUserId,
      plaintext: plaintext,
      createdAt: DateTime.now().toUtc(),
      delivery: ChatDeliveryState.sending,
      isMine: true,
    );

    try {
      final envelope = await api.sendEnvelope(
        token: token,
        conversationId: conversationId,
        clientMessageId: clientMessageId,
        ciphertext: wire.bytes,
        contentType: MlsContentTypes.application,
      );
      return pending.copyWith(
        delivery: ChatDeliveryState.sent,
        serverEnvelopeId: envelope.id,
      );
    } catch (_) {
      return pending.copyWith(
        delivery: ChatDeliveryState.failed,
        error: 'Send failed',
      );
    }
  }

  void bindConversationPeer(String conversationId, String peerUserId) {
    _peerByConversation[conversationId] = peerUserId;
  }

  Future<List<ChatMessageView>> ingestEnvelopes({
    required String token,
    required String myUserId,
    required List<MessageEnvelope> envelopes,
  }) async {
    final svc = mls.service;
    if (svc == null) throw StateError('MLS not ready');

    final sorted = [...envelopes]..sort(compareEnvelopesForProcessing);
    final out = <ChatMessageView>[];
    final deferred = <MessageEnvelope>[];

    Future<void> processOne(MessageEnvelope env) async {
      if (_processedEnvelopeIds.contains(env.id)) return;

      if (!_isAuthorizedSender(env, myUserId)) {
        // Do not decrypt or display — membership/sender check failed.
        return;
      }

      if (env.senderId == myUserId &&
          env.contentType == MlsContentTypes.application) {
        _processedEnvelopeIds.add(env.id);
        return;
      }

      if (env.contentType == MlsContentTypes.welcome) {
        final groupId =
            await svc.joinFromWelcome(welcomeBytes: env.ciphertext);
        _groupByConversation[env.conversationId] = groupId;
        _joinedViaWelcome.add(env.conversationId);
        // Ack only after successful cryptographic processing (C4).
        await api.acknowledgeEnvelope(token: token, envelopeId: env.id);
        _processedEnvelopeIds.add(env.id);
        return;
      }

      final groupId = _groupByConversation[env.conversationId];
      if (groupId == null) {
        deferred.add(env);
        return;
      }

      if (env.contentType == MlsContentTypes.commit ||
          env.contentType == MlsContentTypes.proposal) {
        try {
          await svc.processIncoming(
            groupIdHex: groupId,
            messageBytes: env.ciphertext,
          );
        } catch (_) {
          // Joiners often already advanced via Welcome; a redundant Commit for
          // the same epoch must not block recovery or cause silent discard of
          // later application messages. Other crypto failures still surface.
          if (!_joinedViaWelcome.contains(env.conversationId)) {
            rethrow;
          }
        }
        await api.acknowledgeEnvelope(token: token, envelopeId: env.id);
        _processedEnvelopeIds.add(env.id);
        return;
      }

      final decrypted = await svc.processIncoming(
        groupIdHex: groupId,
        messageBytes: env.ciphertext,
      );

      if (env.contentType == MlsContentTypes.callKeyBinding) {
        if (decrypted == null) {
          throw StateError('call key binding produced no plaintext');
        }
        await api.acknowledgeEnvelope(token: token, envelopeId: env.id);
        _processedEnvelopeIds.add(env.id);
        return;
      }

      if (env.contentType == MlsContentTypes.application) {
        if (decrypted == null) {
          // Failed crypto must not silently ack/discard (C4).
          throw StateError('application message produced no plaintext');
        }
        await api.acknowledgeEnvelope(token: token, envelopeId: env.id);
        _processedEnvelopeIds.add(env.id);
        out.add(
          ChatMessageView(
            clientMessageId: env.clientMessageId,
            serverEnvelopeId: env.id,
            senderId: env.senderId,
            plaintext: utf8.decode(decrypted.plaintext),
            createdAt: env.createdAt,
            delivery: ChatDeliveryState.sent,
            isMine: env.senderId == myUserId,
          ),
        );
        return;
      }

      await api.acknowledgeEnvelope(token: token, envelopeId: env.id);
      _processedEnvelopeIds.add(env.id);
    }

    for (final env in sorted) {
      try {
        await processOne(env);
      } catch (_) {
        keyChangeWarning =
            'A message could not be decrypted. Verify your contact\'s safety number.';
      }
    }

    // After Welcome, retry envelopes that arrived before local join.
    if (deferred.isNotEmpty) {
      deferred.sort(compareEnvelopesForProcessing);
      for (final env in deferred) {
        try {
          await processOne(env);
        } catch (_) {
          keyChangeWarning =
              'A message could not be decrypted. Verify your contact\'s safety number.';
        }
      }
    }
    return out;
  }

  bool _isAuthorizedSender(MessageEnvelope env, String myUserId) {
    if (env.senderId == myUserId) return true;
    final peer = _peerByConversation[env.conversationId];
    if (peer != null) return env.senderId == peer;
    // Unknown conversation binding — refuse display until peer is bound.
    return false;
  }

  void _trackFingerprint(String peerUserId, String fingerprint, {String? deviceId}) {
    final prior = _knownFingerprints[peerUserId];
    if (prior != null && prior != fingerprint) {
      keyChangeWarning =
          'Safety number changed for this contact. Verify before continuing.';
    }
    _knownFingerprints[peerUserId] = fingerprint;
    if (deviceId != null) {
      unawaited(persistMessagingDevicePin(deviceId, fingerprint));
    }
  }
}
