import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/crypto/mls_session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_config.dart';
import 'delivery_timing.dart';
import 'encrypted_conversation_service.dart';
import 'models/envelope.dart';
import 'realtime_client.dart';

/// Chooses what [ConversationController.open] may hand to MLS.
///
/// Only pending deliveries are cryptographic inputs. Acknowledged history,
/// including application and call-key-binding ciphertext, is not replayed.
/// An id that appears in both lists is returned once, preferring the pending
/// copy. The result is ordered by conversation sequence and protocol rank,
/// the same rule [ingestEnvelopes] uses, not by envelope id.
List<MessageEnvelope> selectEnvelopesForIngest({
  required List<MessageEnvelope> history,
  required List<MessageEnvelope> pending,
}) {
  final pendingIds = pending.map((envelope) => envelope.id).toSet();
  final selected = <MessageEnvelope>[];
  final seen = <String>{};

  void consider(MessageEnvelope envelope) {
    if (!pendingIds.contains(envelope.id)) return;
    if (!seen.add(envelope.id)) return;
    selected.add(envelope);
  }

  for (final envelope in pending) {
    consider(envelope);
  }
  for (final envelope in history) {
    consider(envelope);
  }
  selected.sort(compareEnvelopesForProcessing);
  return selected;
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
  int _syncDepth = 0;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> open() async {
    loadState = ConversationLoadState.loading;
    errorMessage = null;
    _notify();

    final openSpan = DeliveryTiming.start();
    try {
      await mls.ensureReady(auth);
      openSpan.lap('open_ensure_ready');
      final token = await auth.sessionToken();
      if (token == null) throw StateError('No token');

      await _service.enrollDevice(token);
      openSpan.lap('open_enroll');
      final info = await _service.openWithPeer(
        token: token,
        myUserId: auth.state.userId!,
        peerUserId: peerUserId,
      );
      openSpan.lap('open_peer');
      conversationId = info.conversationId;
      _service.bindConversationPeer(info.conversationId, peerUserId);

      // Only pending deliveries are decrypted. Acknowledged history is not
      // replayed into OpenMLS.
      final pending = await api.syncPending(token: token);
      openSpan.lap('open_sync_pending');
      final history = await api.listEnvelopes(
        token: token,
        conversationId: info.conversationId,
      );
      openSpan.lap('open_list_envelopes');
      await _service.ingestEnvelopes(
        token: token,
        myUserId: auth.state.userId!,
        envelopes: selectEnvelopesForIngest(history: history, pending: pending),
      );
      openSpan.lap('open_ingest');
      await restoreLocalHistory();
      openSpan.lap('open_restore');
      keyChangeWarning = _service.keyChangeWarning;

      await _realtime.start(token);
      openSpan.lap('open_realtime');
      _rtSub = _realtime.events.listen((event) {
        DeliveryTiming.record(
          'realtime_event',
          openSpan.elapsedMilliseconds,
          detail: _eventType(event),
        );
        _syncNow();
      });
      DeliveryTiming.record(
        'realtime_listener_attached',
        openSpan.elapsedMilliseconds,
      );
      openSpan.total('open_total');

      loadState = ConversationLoadState.ready;
      offline = false;
    } catch (e) {
      openSpan.total('open_failed');
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
    final overlapped = _syncDepth > 0;
    _syncDepth++;
    final span = DeliveryTiming.start();
    if (overlapped) {
      DeliveryTiming.record('sync_overlap', _syncDepth);
    }
    try {
      final pending = await api.syncPending(token: token);
      span.lap('sync_pending_http');
      final mine = pending.where((e) => e.conversationId == cid).toList();
      await _service.ingestEnvelopes(
        token: token,
        myUserId: auth.state.userId!,
        envelopes: mine,
      );
      span.lap('sync_ingest');
      final before = _transcriptKey();
      await restoreLocalHistory();
      span.lap('sync_restore');
      span.total('sync_total');
      final warning = _service.keyChangeWarning;
      final warningChanged = warning != null && warning != keyChangeWarning;
      if (warningChanged) keyChangeWarning = warning;
      final wasOffline = offline;
      offline = false;
      if (before != _transcriptKey() || warningChanged || wasOffline) {
        _notify();
      }
    } catch (_) {
      span.total('sync_failed');
      offline = true;
      _notify();
    } finally {
      _syncDepth--;
    }
  }

  String _eventType(Map<String, dynamic> event) {
    final type = event['type'];
    if (type is! String) return 'unknown';
    return type;
  }

  /// Replaces the visible transcript with stored history, keeping outgoing rows.
  @visibleForTesting
  Future<void> restoreLocalHistory() async {
    final cid = conversationId;
    final userId = auth.state.userId;
    if (cid == null || userId == null) return;
    final stored = await _service.localTranscript(
      conversationId: cid,
      myUserId: userId,
    );
    final outgoing = messages.where((message) => message.isMine).toList();
    messages
      ..clear()
      ..addAll(stored);
    for (final message in outgoing) {
      final kept = messages.any(
        (existing) => existing.clientMessageId == message.clientMessageId,
      );
      if (!kept) messages.add(message);
    }
  }

  String _transcriptKey() {
    return messages
        .map(
          (message) =>
              '${message.clientMessageId}|${message.serverEnvelopeId}|'
              '${message.delivery.name}|${message.plaintext.hashCode}',
        )
        .join('\n');
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
