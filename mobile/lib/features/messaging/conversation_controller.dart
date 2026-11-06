import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/crypto/mls_session_manager.dart';
import '../../core/crypto/protocol_messages.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_config.dart';
import 'encrypted_conversation_service.dart';
import 'models/envelope.dart';
import 'realtime_client.dart';

/// Chooses what [ConversationController.open] may hand to MLS.
///
/// Handshake envelopes are processed only while they are still pending.
/// An acknowledged Welcome, Commit, or Proposal stays in history and is not
/// replayed. Application envelopes in history are kept so they can be
/// displayed, but an id that is also pending is returned once. [ingestEnvelopes]
/// then sorts by conversation sequence, so an earlier epoch is applied before
/// a later one.
List<MessageEnvelope> selectEnvelopesForIngest({
  required List<MessageEnvelope> history,
  required List<MessageEnvelope> pending,
}) {
  final pendingIds = pending.map((envelope) => envelope.id).toSet();
  final selected = <MessageEnvelope>[];
  final seen = <String>{};

  void consider(MessageEnvelope envelope) {
    if (!seen.add(envelope.id)) return;
    if (_isHandshake(envelope.contentType) && !pendingIds.contains(envelope.id)) {
      return;
    }
    selected.add(envelope);
  }

  for (final envelope in history) {
    consider(envelope);
  }
  for (final envelope in pending) {
    consider(envelope);
  }
  return selected;
}

bool _isHandshake(String contentType) {
  switch (contentType) {
    case MlsContentTypes.welcome:
    case MlsContentTypes.commit:
    case MlsContentTypes.proposal:
      return true;
    default:
      return false;
  }
}

enum ConversationLoadState { idle, loading, ready, error }

class ConversationController extends ChangeNotifier {
  ConversationController({
    required this.api,
    required this.auth,
    required this.mls,
    required this.peerUserId,
    required this.peerEmail,
    EncryptedConversationService? service,
    RealtimeClient? realtime,
  })  : _service = service ??
            EncryptedConversationService(api: api, mls: mls),
        _realtime = realtime ??
            RealtimeClient(
              wsBaseUri: ApiConfig.baseUri.replace(
                scheme: ApiConfig.baseUri.scheme == 'https' ? 'wss' : 'ws',
                path: '/realtime/ws',
              ),
            );

  final ApiClient api;
  final AuthController auth;
  final MlsSessionManager mls;
  final String peerUserId;
  final String peerEmail;
  final EncryptedConversationService _service;
  final RealtimeClient _realtime;

  ConversationLoadState loadState = ConversationLoadState.idle;
  String? errorMessage;
  String? conversationId;
  String? keyChangeWarning;
  bool offline = false;
  final List<ChatMessageView> messages = [];
  StreamSubscription? _rtSub;
  bool _disposed = false;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> open() async {
    loadState = ConversationLoadState.loading;
    errorMessage = null;
    _notify();

    try {
      await mls.ensureReady(auth);
      final token = await auth.sessionToken();
      if (token == null) throw StateError('No token');

      await _service.enrollDevice(token);
      final info = await _service.openWithPeer(
        token: token,
        myUserId: auth.state.userId!,
        peerUserId: peerUserId,
      );
      conversationId = info.conversationId;
      _service.bindConversationPeer(info.conversationId, peerUserId);

      // Pending envelopes drive handshake processing. History is display
      // material and must not replay an acknowledged Welcome or Commit.
      final pending = await api.syncPending(token: token);
      final history = await api.listEnvelopes(
        token: token,
        conversationId: info.conversationId,
      );
      final incoming = await _service.ingestEnvelopes(
        token: token,
        myUserId: auth.state.userId!,
        envelopes: selectEnvelopesForIngest(history: history, pending: pending),
      );
      messages
        ..clear()
        ..addAll(incoming);
      keyChangeWarning = _service.keyChangeWarning;

      await _realtime.start(token);
      _rtSub = _realtime.events.listen((_) => _syncNow());

      loadState = ConversationLoadState.ready;
      offline = false;
    } catch (e) {
      loadState = ConversationLoadState.error;
      offline = true;
      errorMessage = 'Unable to open secure conversation';
    }
    _notify();
  }

  Future<void> _syncNow() async {
    final token = await auth.sessionToken();
    final cid = conversationId;
    if (token == null || cid == null) return;
    try {
      final pending = await api.syncPending(token: token);
      final mine = pending.where((e) => e.conversationId == cid).toList();
      final added = await _service.ingestEnvelopes(
        token: token,
        myUserId: auth.state.userId!,
        envelopes: mine,
      );
      if (added.isNotEmpty) {
        messages.addAll(added);
      }
      final warning = _service.keyChangeWarning;
      final warningChanged = warning != null && warning != keyChangeWarning;
      if (warningChanged) keyChangeWarning = warning;
      final wasOffline = offline;
      offline = false;
      if (added.isNotEmpty || warningChanged || wasOffline) {
        _notify();
      }
    } catch (_) {
      offline = true;
      _notify();
    }
  }

  Future<void> send(String text, {String? clientMessageId}) async {
    if (_disposed) return;
    final token = await auth.sessionToken();
    final cid = conversationId;
    final userId = auth.state.userId;
    if (_disposed || token == null || cid == null || userId == null) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final clientId =
        clientMessageId ?? 'c-${DateTime.now().microsecondsSinceEpoch}';
    final prior = messages.indexWhere((m) => m.clientMessageId == clientId);
    if (prior >= 0 && messages[prior].delivery == ChatDeliveryState.sent) {
      return;
    }
    final optimistic = ChatMessageView(
      clientMessageId: clientId,
      senderId: userId,
      plaintext: trimmed,
      createdAt:
          prior >= 0 ? messages[prior].createdAt : DateTime.now().toUtc(),
      delivery: ChatDeliveryState.sending,
      isMine: true,
    );
    if (prior >= 0) {
      messages[prior] = optimistic;
    } else {
      messages.add(optimistic);
    }
    _notify();

    final ChatMessageView result;
    try {
      result = await _service.sendText(
        token: token,
        conversationId: cid,
        myUserId: userId,
        plaintext: trimmed,
        clientMessageId: clientId,
      );
    } catch (error, stack) {
      if (_disposed) return;
      final trace = error is MlsSendFailure ? (error.stack ?? stack) : stack;
      if (error is MlsSendFailure) {
        MlsDiagnostics.debugStack(trace);
      } else {
        MlsDiagnostics.record(
          stage: 'send',
          error: error,
          stack: trace,
          includeStack: true,
        );
      }
      final failed = optimistic.copyWith(
        delivery: ChatDeliveryState.failed,
        error: 'Message could not be sent.',
      );
      final idx = messages.indexWhere((m) => m.clientMessageId == clientId);
      if (idx >= 0) messages[idx] = failed;
      _notify();
      return;
    }
    if (_disposed) return;
    final idx = messages.indexWhere((m) => m.clientMessageId == clientId);
    if (idx >= 0) {
      messages[idx] = result;
      _notify();
    }
  }

  void dismissKeyChangeWarning() {
    keyChangeWarning = null;
    _notify();
  }

  Future<void> retry(String clientMessageId) async {
    if (_disposed) return;
    final idx = messages.indexWhere((m) => m.clientMessageId == clientMessageId);
    if (idx < 0) return;
    final existing = messages[idx];
    if (existing.delivery != ChatDeliveryState.failed) return;
    await send(existing.plaintext, clientMessageId: clientMessageId);
  }

  @override
  void dispose() {
    _disposed = true;
    _rtSub?.cancel();
    _realtime.dispose();
    super.dispose();
  }
}
