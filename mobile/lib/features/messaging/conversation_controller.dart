import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/crypto/mls_session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_config.dart';
import 'encrypted_conversation_service.dart';
import 'models/envelope.dart';
import 'realtime_client.dart';

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

  Future<void> open() async {
    loadState = ConversationLoadState.loading;
    errorMessage = null;
    notifyListeners();

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

      // Joiner path: ingest history/pending for Welcome.
      final pending = await api.syncPending(token: token);
      final history = await api.listEnvelopes(
        token: token,
        conversationId: info.conversationId,
      );
      final incoming = await _service.ingestEnvelopes(
        token: token,
        myUserId: auth.state.userId!,
        envelopes: [...history.reversed, ...pending],
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
    notifyListeners();
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
        keyChangeWarning = _service.keyChangeWarning;
        notifyListeners();
      }
      offline = false;
    } catch (_) {
      offline = true;
      notifyListeners();
    }
  }

  Future<void> send(String text) async {
    final token = await auth.sessionToken();
    final cid = conversationId;
    final userId = auth.state.userId;
    if (token == null || cid == null || userId == null) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final clientId = 'c-${DateTime.now().microsecondsSinceEpoch}';
    final optimistic = ChatMessageView(
      clientMessageId: clientId,
      senderId: userId,
      plaintext: trimmed,
      createdAt: DateTime.now().toUtc(),
      delivery: ChatDeliveryState.sending,
      isMine: true,
    );
    messages.add(optimistic);
    notifyListeners();

    final result = await _service.sendText(
      token: token,
      conversationId: cid,
      myUserId: userId,
      plaintext: trimmed,
      clientMessageId: clientId,
    );
    final idx = messages.indexWhere((m) => m.clientMessageId == clientId);
    if (idx >= 0) {
      messages[idx] = result;
      notifyListeners();
    }
  }

  void dismissKeyChangeWarning() {
    keyChangeWarning = null;
    notifyListeners();
  }

  Future<void> retry(String clientMessageId) async {
    final existing = messages.cast<ChatMessageView?>().firstWhere(
          (m) => m!.clientMessageId == clientMessageId,
          orElse: () => null,
        );
    if (existing == null || existing.delivery != ChatDeliveryState.failed) {
      return;
    }
    messages.removeWhere((m) => m.clientMessageId == clientMessageId);
    await send(existing.plaintext);
  }

  @override
  void dispose() {
    _rtSub?.cancel();
    _realtime.dispose();
    super.dispose();
  }
}
