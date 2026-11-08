import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/crypto/mls_session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_config.dart';
import '../../core/ui/connectivity_banner.dart';
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
    bool ownRealtime = true,
  })  : _service = service ??
            EncryptedConversationService(api: api, mls: mls),
        _realtime = realtime ??
            RealtimeClient(
              wsBaseUri: ApiConfig.baseUri.replace(
                scheme: ApiConfig.baseUri.scheme == 'https' ? 'wss' : 'ws',
                path: '/realtime/ws',
              ),
            ),
        _ownRealtime = realtime == null ? true : ownRealtime;

  final ApiClient api;
  final AuthController auth;
  final MlsSessionManager mls;
  final String peerUserId;
  final String peerEmail;
  final EncryptedConversationService _service;
  final RealtimeClient _realtime;
  final bool _ownRealtime;

  ConversationLoadState loadState = ConversationLoadState.idle;
  String? errorMessage;
  String? conversationId;
  String? keyChangeWarning;
  bool offline = false;
  ConnectivityBannerState linkState = ConnectivityBannerState.hidden;
  final List<ChatMessageView> messages = [];
  StreamSubscription? _rtSub;
  bool _disposed = false;
  Future<void> _syncChain = Future<void>.value();

  void _setLinkState(ConnectivityBannerState next) {
    if (linkState == next) return;
    linkState = next;
    offline = next != ConnectivityBannerState.hidden;
  }

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
      final token = await auth.sessionToken();
      if (token == null) throw StateError('No token');

      // Attach the listener before enrollment/network work so envelope
      // hints are not dropped from the broadcast stream.
      await _attachRealtime(token);
      openSpan.lap('open_realtime');

      await mls.ensureReady(auth);
      openSpan.lap('open_ensure_ready');

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

      // Show durable history before network ingest so reopen feels instant.
      await restoreLocalHistory();
      openSpan.lap('open_restore_early');
      _notify();

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
      openSpan.total('open_total');

      loadState = ConversationLoadState.ready;
      _setLinkState(ConnectivityBannerState.hidden);
    } catch (e) {
      openSpan.total('open_failed');
      // Keep durable local history visible; a network failure is not deletion.
      if (messages.isNotEmpty) {
        loadState = ConversationLoadState.ready;
        errorMessage = null;
        _setLinkState(ConnectivityBannerState.unreachable);
      } else {
        loadState = ConversationLoadState.error;
        _setLinkState(ConnectivityBannerState.unreachable);
        errorMessage =
            'Unable to open this conversation right now. '
            'Your encrypted messages were not deleted.';
      }
    }
    _notify();
  }

  Future<void> _attachRealtime(String token) async {
    await _rtSub?.cancel();
    _rtSub = _realtime.events.listen((event) {
      final type = _eventType(event);
      DeliveryTiming.record('realtime_event', 0, detail: type);
      if (type == 'client_reconnecting') {
        _setLinkState(ConnectivityBannerState.reconnecting);
        _notify();
      }
      if (type == 'connected' ||
          type == 'envelope' ||
          type == 'client_reconnecting') {
        DeliveryTiming.record('sync_trigger', 0, detail: type);
        unawaited(_syncNow());
      }
    });
    DeliveryTiming.record('realtime_listener_attached', 0);
    if (!_realtime.isStarted) {
      await _realtime.start(token);
    }
  }

  Future<void> _syncNow() {
    final result = _syncChain.then((_) => _runSync());
    _syncChain = result.catchError((_) {});
    return result;
  }

  Future<void> _runSync() async {
    final token = await auth.sessionToken();
    final cid = conversationId;
    if (token == null || cid == null || _disposed) return;
    final span = DeliveryTiming.start();
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
      final wasDegraded = linkState != ConnectivityBannerState.hidden;
      _setLinkState(ConnectivityBannerState.hidden);
      if (before != _transcriptKey() || warningChanged || wasDegraded) {
        _notify();
      }
    } catch (_) {
      span.total('sync_failed');
      _setLinkState(ConnectivityBannerState.unreachable);
      _notify();
    }
  }

  String _eventType(Map<String, dynamic> event) {
    final type = event['type'];
    if (type is! String) return 'unknown';
    return type;
  }

  /// Replaces the visible transcript with stored history, keeping in-flight rows.
  @visibleForTesting
  Future<void> restoreLocalHistory() async {
    final cid = conversationId;
    final userId = auth.state.userId;
    if (cid == null || userId == null) return;
    final stored = await _service.localTranscript(
      conversationId: cid,
      myUserId: userId,
    );
    final inFlight = messages
        .where(
          (message) =>
              message.delivery == ChatDeliveryState.sending ||
              (message.isMine &&
                  (message.delivery == ChatDeliveryState.failed ||
                      message.delivery == ChatDeliveryState.uncertain ||
                      message.delivery == ChatDeliveryState.blocked) &&
                  !stored.any(
                    (row) => row.clientMessageId == message.clientMessageId,
                  )),
        )
        .toList();
    messages
      ..clear()
      ..addAll(stored);
    for (final message in inFlight) {
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

  /// Returns `true` when an outgoing row was queued (optimistic or update).
  /// Returns `false` when send was ignored (no session/conversation/blank).
  Future<bool> send(String text, {String? clientMessageId}) async {
    if (_disposed) return false;
    final token = await auth.sessionToken();
    final cid = conversationId;
    final userId = auth.state.userId;
    if (_disposed || token == null || cid == null || userId == null) {
      DeliveryTiming.record(
        'send_ignored',
        0,
        detail: 'token=${token != null};cid=${cid != null};user=${userId != null}',
      );
      return false;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    final clientId =
        clientMessageId ?? 'c-${DateTime.now().microsecondsSinceEpoch}';
    final prior = messages.indexWhere((m) => m.clientMessageId == clientId);
    if (prior >= 0 && messages[prior].delivery == ChatDeliveryState.sent) {
      return true;
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
        createdAt: optimistic.createdAt,
      );
    } catch (error, stack) {
      if (_disposed) return true;
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
      await restoreLocalHistory();
      _applySendResult(
        clientId: clientId,
        delivery: ChatDeliveryState.failed,
        error: null,
      );
      _notify();
      return true;
    }
    if (_disposed) return true;
    await restoreLocalHistory();
    _applySendResult(
      clientId: clientId,
      delivery: result.delivery,
      serverEnvelopeId: result.serverEnvelopeId,
      error: result.error,
    );
    _notify();
    return true;
  }

  void _applySendResult({
    required String clientId,
    required ChatDeliveryState delivery,
    String? serverEnvelopeId,
    String? error,
  }) {
    final idx = messages.indexWhere((m) => m.clientMessageId == clientId);
    if (idx < 0) return;
    final current = messages[idx];
    messages[idx] = ChatMessageView(
      clientMessageId: current.clientMessageId,
      serverEnvelopeId: serverEnvelopeId ?? current.serverEnvelopeId,
      senderId: current.senderId,
      plaintext: current.plaintext,
      createdAt: current.createdAt,
      delivery: delivery,
      isMine: current.isMine,
      error: error,
    );
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
    // Explicit user action only. failed/uncertain resubmit durable ciphertext.
    // blocked must not re-encrypt under the same client_message_id.
    if (existing.delivery != ChatDeliveryState.failed &&
        existing.delivery != ChatDeliveryState.uncertain) {
      return;
    }
    await send(existing.plaintext, clientMessageId: clientMessageId);
  }

  @override
  void dispose() {
    _disposed = true;
    _rtSub?.cancel();
    _rtSub = null;
    if (_ownRealtime) {
      _realtime.dispose();
    }
    super.dispose();
  }
}
