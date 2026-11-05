import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../messaging/realtime_client.dart';
import 'call_service.dart';
import 'calling_api_client.dart';
import 'models/call_session.dart';

enum CallPhase {
  idle,
  outgoingRinging,
  incomingRinging,
  connecting,
  connected,
  ended,
  failed,
}

/// Orchestrates signaling + media. No WebRTC calls inside widgets.
class CallController extends ChangeNotifier {
  CallController({
    required this.api,
    required this.media,
    required this.myUserId,
    required this.tokenProvider,
    this.realtime,
    this.hintEvents,
    this.requestPermissions = _defaultPermissions,
  });

  final CallingApiClient api;
  final CallService media;
  final String myUserId;
  final String Function() tokenProvider;
  final RealtimeClient? realtime;
  final Stream<Map<String, dynamic>>? hintEvents;
  final Future<bool> Function(CallMediaType mediaType) requestPermissions;

  CallPhase phase = CallPhase.idle;
  CallSession? session;
  String? error;
  bool micMuted = false;
  bool speakerOn = false;
  bool cameraEnabled = true;
  DateTime? connectedAt;
  int _iceAfter = 0;
  final Set<String> _processedAnswers = {};
  final Set<String> _processedOffers = {};
  StreamSubscription? _rtSub;
  StreamSubscription? _mediaSub;
  Timer? _poll;
  Timer? _ringTimer;

  Duration get duration {
    if (connectedAt == null) return Duration.zero;
    return DateTime.now().toUtc().difference(connectedAt!);
  }

  Future<void> startListening() async {
    await _mediaSub?.cancel();
    _mediaSub = media.events.listen(_onMediaEvent);
    await _rtSub?.cancel();
    _rtSub = (hintEvents ?? realtime?.events)?.listen(_onRealtime);
    await reconcileActive();
  }

  Future<void> reconcileActive() async {
    try {
      final active = await api.active(token: tokenProvider());
      if (active == null || active.isEnded) {
        if (phase != CallPhase.idle && phase != CallPhase.ended) {
          await _cleanupLocal(ended: true);
        }
        return;
      }
      session = active;
      if (active.state == CallRemoteState.ringing) {
        phase = active.callerUserId == myUserId
            ? CallPhase.outgoingRinging
            : CallPhase.incomingRinging;
      } else if (active.state == CallRemoteState.connected) {
        phase = CallPhase.connected;
        connectedAt ??= DateTime.now().toUtc();
      } else {
        phase = CallPhase.connecting;
      }
      notifyListeners();
      _startPollingIce();
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  Future<void> startOutgoing({
    required String peerUserId,
    required CallMediaType mediaType,
  }) async {
    if (phase != CallPhase.idle) return;
    error = null;
    final allowed = await requestPermissions(mediaType);
    if (!allowed) {
      error = 'Microphone${mediaType == CallMediaType.video ? '/camera' : ''} permission denied';
      phase = CallPhase.failed;
      notifyListeners();
      return;
    }
    try {
      await media.prepareOutgoing(
        mediaType: mediaType,
        enableVideo: mediaType == CallMediaType.video,
      );
      final clientId = 'c-${DateTime.now().microsecondsSinceEpoch}';
      session = await api.initiate(
        token: tokenProvider(),
        calleeUserId: peerUserId,
        mediaType: mediaType,
        clientCallId: clientId,
      );
      phase = CallPhase.outgoingRinging;
      notifyListeners();
      _armRingTimeout();
      final offer = await media.createOffer();
      session = await api.setOffer(
        token: tokenProvider(),
        callId: session!.id,
        sdp: offer,
      );
      _processedOffers.add(offer);
      _startPollingIce();
    } catch (e) {
      error = e.toString();
      phase = CallPhase.failed;
      await media.disposeMedia();
      notifyListeners();
    }
  }

  Future<void> acceptIncoming() async {
    final current = session;
    if (current == null) return;
    final allowed = await requestPermissions(current.mediaType);
    if (!allowed) {
      error = 'Permission denied';
      phase = CallPhase.failed;
      notifyListeners();
      return;
    }
    try {
      await media.prepareIncoming(
        mediaType: current.mediaType,
        enableVideo: current.mediaType == CallMediaType.video,
      );
      session = await api.accept(token: tokenProvider(), callId: current.id);
      phase = CallPhase.connecting;
      notifyListeners();
      _ringTimer?.cancel();
      final fresh = await api.get(token: tokenProvider(), callId: current.id);
      session = fresh;
      if (fresh.sdpOffer != null && !_processedOffers.contains(fresh.sdpOffer)) {
        await media.applyRemoteOffer(fresh.sdpOffer!);
        _processedOffers.add(fresh.sdpOffer!);
        final answer = await media.createAnswer();
        session = await api.setAnswer(
          token: tokenProvider(),
          callId: current.id,
          sdp: answer,
        );
        _processedAnswers.add(answer);
      }
      _startPollingIce();
    } catch (e) {
      error = e.toString();
      phase = CallPhase.failed;
      await media.disposeMedia();
      notifyListeners();
    }
  }

  Future<void> declineIncoming() async {
    final id = session?.id;
    if (id == null) return;
    try {
      session = await api.decline(token: tokenProvider(), callId: id);
    } finally {
      await _cleanupLocal(ended: true);
    }
  }

  Future<void> cancelOutgoing() async {
    final id = session?.id;
    if (id == null) return;
    try {
      session = await api.cancel(token: tokenProvider(), callId: id);
    } finally {
      await _cleanupLocal(ended: true);
    }
  }

  Future<void> hangUp() async {
    final id = session?.id;
    if (id != null) {
      try {
        session = await api.hangup(token: tokenProvider(), callId: id);
      } catch (_) {}
    }
    await _cleanupLocal(ended: true);
  }

  Future<void> onLogout() async {
    await hangUp();
  }

  Future<void> toggleMute() async {
    micMuted = !micMuted;
    await media.setMicrophoneMuted(micMuted);
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    await media.setSpeakerphone(speakerOn);
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    cameraEnabled = !cameraEnabled;
    await media.setCameraEnabled(cameraEnabled);
    notifyListeners();
  }

  Future<void> switchCamera() => media.switchCamera();

  void _onRealtime(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    final callId = event['call_id'] as String?;
    if (type == null || callId == null) return;
    if (!type.startsWith('call.')) return;
    unawaited(_refreshFromServer(callId));
  }

  Future<void> _refreshFromServer(String callId) async {
    try {
      final fresh = await api.get(token: tokenProvider(), callId: callId);
      session = fresh;
      if (fresh.isEnded) {
        await _cleanupLocal(ended: true);
        return;
      }
      if (fresh.state == CallRemoteState.ringing &&
          fresh.calleeUserId == myUserId &&
          phase == CallPhase.idle) {
        phase = CallPhase.incomingRinging;
        _armRingTimeout();
        notifyListeners();
        return;
      }
      if (fresh.sdpAnswer != null &&
          fresh.callerUserId == myUserId &&
          !_processedAnswers.contains(fresh.sdpAnswer)) {
        await media.applyRemoteAnswer(fresh.sdpAnswer!);
        _processedAnswers.add(fresh.sdpAnswer!);
        phase = CallPhase.connecting;
      }
      if (fresh.state == CallRemoteState.connected) {
        phase = CallPhase.connected;
        connectedAt ??= DateTime.now().toUtc();
      }
      notifyListeners();
      await _pullIce();
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  void _onMediaEvent(CallMediaEvent event) {
    switch (event.kind) {
      case CallMediaEventKind.localIce:
        final id = session?.id;
        if (id == null || event.candidate == null) return;
        unawaited(api.addIce(
          token: tokenProvider(),
          callId: id,
          candidate: event.candidate!,
          clientIceId: event.clientIceId ?? 'ice-${DateTime.now().microsecondsSinceEpoch}',
          sdpMid: event.sdpMid,
          sdpMLineIndex: event.sdpMLineIndex,
        ));
      case CallMediaEventKind.connectionConnected:
        phase = CallPhase.connected;
        connectedAt ??= DateTime.now().toUtc();
        notifyListeners();
        final id = session?.id;
        if (id != null) {
          unawaited(api.markConnected(token: tokenProvider(), callId: id));
        }
      case CallMediaEventKind.connectionFailed:
        error = 'Connection failed';
        phase = CallPhase.failed;
        notifyListeners();
        unawaited(hangUp());
      case CallMediaEventKind.connectionDisconnected:
        // Keep call; allow brief reconnect.
        break;
    }
  }

  void _startPollingIce() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pullIce());
  }

  Future<void> _pullIce() async {
    final id = session?.id;
    if (id == null) return;
    try {
      final items = await api.listIce(
        token: tokenProvider(),
        callId: id,
        after: _iceAfter,
      );
      for (final ice in items) {
        if (ice.seq > _iceAfter) _iceAfter = ice.seq;
        await media.addRemoteIce(
          candidate: ice.candidate,
          sdpMid: ice.sdpMid,
          sdpMLineIndex: ice.sdpMLineIndex,
        );
      }
    } catch (_) {}
  }

  void _armRingTimeout() {
    _ringTimer?.cancel();
    final expires = session?.ringExpiresAt;
    final wait = expires == null
        ? const Duration(seconds: 45)
        : expires.difference(DateTime.now().toUtc());
    _ringTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (phase == CallPhase.outgoingRinging || phase == CallPhase.incomingRinging) {
        unawaited(hangUp());
      }
    });
  }

  Future<void> _cleanupLocal({required bool ended}) async {
    _poll?.cancel();
    _ringTimer?.cancel();
    await media.disposeMedia();
    if (ended) {
      phase = CallPhase.ended;
    } else {
      phase = CallPhase.idle;
    }
    micMuted = false;
    speakerOn = false;
    cameraEnabled = true;
    connectedAt = null;
    _iceAfter = 0;
    notifyListeners();
    // Return to idle shortly for UI.
    if (ended) {
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (phase == CallPhase.ended) {
          phase = CallPhase.idle;
          session = null;
          notifyListeners();
        }
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ringTimer?.cancel();
    _rtSub?.cancel();
    _mediaSub?.cancel();
    unawaited(media.disposeMedia());
    super.dispose();
  }

  static Future<bool> _defaultPermissions(CallMediaType mediaType) async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;
    if (mediaType == CallMediaType.video) {
      final cam = await Permission.camera.request();
      return cam.isGranted;
    }
    return true;
  }
}
