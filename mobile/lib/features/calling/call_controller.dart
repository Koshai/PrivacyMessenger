import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../messaging/realtime_client.dart';
import 'call_auth.dart';
import 'call_auth_session.dart';
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
    this.disconnectGrace = const Duration(seconds: 12),
    this.iceSubmitAttempts = 3,
    this.authenticatePeer,
    this.authTimeout = const Duration(seconds: 20),
  });

  final CallingApiClient api;
  final CallService media;
  final String myUserId;
  final String Function() tokenProvider;
  final RealtimeClient? realtime;
  final Stream<Map<String, dynamic>>? hintEvents;
  final Future<bool> Function(CallMediaType mediaType) requestPermissions;
  final Duration disconnectGrace;
  final int iceSubmitAttempts;
  final CallAuthenticator? authenticatePeer;
  final Duration authTimeout;

  /// `incoming`, `ongoing`, or `ended`. The kind carries no signaling payload.
  void Function(String kind)? onLifecycle;

  String authPhase = CallAuthPhase.idle;
  String? peerFingerprintHex;
  String? authenticatedPeerDeviceId;
  String? localSafetyFingerprintHex;
  bool peerManuallyVerified = false;
  List<int>? _observedRemoteDtls;

  /// Remote media is authenticated only after peer verification.
  /// A missing authenticator is not a bypass.
  bool get remoteMediaAuthenticated => authPhase == CallAuthPhase.authenticated;

  /// coarse, user-visible link state. Not a proof of identity.
  String linkQuality = 'idle';

  CallPhase phase = CallPhase.idle;
  CallSession? session;
  String? error;
  bool micMuted = false;
  bool speakerOn = false;
  bool cameraEnabled = true;
  DateTime? connectedAt;

  /// True only after a local WebRTC connected/completed indication.
  bool localMediaConnected = false;

  int _iceAfter = 0;
  final Set<int> _appliedIceSeq = {};
  final Set<String> _processedAnswers = {};
  final Set<String> _processedOffers = {};
  StreamSubscription? _rtSub;
  StreamSubscription? _mediaSub;
  Timer? _poll;
  Timer? _ringTimer;
  Timer? _disconnectTimer;
  int _generation = 0;
  bool _ending = false;
  bool _mediaReleased = false;

  String? _lifecycleKind;

  @override
  void notifyListeners() {
    super.notifyListeners();
    final kind = switch (phase) {
      CallPhase.incomingRinging => 'incoming',
      CallPhase.outgoingRinging || CallPhase.connecting || CallPhase.connected => 'ongoing',
      _ => 'ended',
    };
    if (phase == CallPhase.idle && _lifecycleKind == null) return;
    if (_lifecycleKind == kind) return;
    _lifecycleKind = kind;
    final hook = onLifecycle;
    if (hook != null) hook(kind);
  }

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
    final gen = _generation;
    try {
      final active = await api.active(token: tokenProvider());
      if (!_isCurrent(gen)) return;
      if (active == null || active.isEnded) {
        if (phase != CallPhase.idle && phase != CallPhase.ended) {
          await _cleanupLocal(ended: true);
        }
        return;
      }
      session = active;
      _applyAuthoritativeState(active, localConnection: localMediaConnected);
      notifyListeners();
      _startPollingIce();
    } catch (e) {
      if (!_isCurrent(gen)) return;
      error = e.toString();
      notifyListeners();
    }
  }

  Future<void> startOutgoing({
    required String peerUserId,
    required CallMediaType mediaType,
  }) async {
    if (phase != CallPhase.idle && phase != CallPhase.ended && phase != CallPhase.failed) {
      return;
    }
    _beginCall();
    error = null;
    final gen = _generation;
    final allowed = await requestPermissions(mediaType);
    if (!_isCurrent(gen)) return;
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
      if (!_isCurrent(gen)) return;
      final clientId = 'c-${DateTime.now().microsecondsSinceEpoch}';
      session = await api.initiate(
        token: tokenProvider(),
        calleeUserId: peerUserId,
        mediaType: mediaType,
        clientCallId: clientId,
      );
      if (!_isCurrent(gen)) return;
      phase = CallPhase.outgoingRinging;
      notifyListeners();
      _armRingTimeout();
      final offer = await media.createOffer();
      if (!_isCurrent(gen) || session == null) return;
      session = await api.setOffer(
        token: tokenProvider(),
        callId: session!.id,
        sdp: offer,
      );
      _processedOffers.add(offer);
      _startPollingIce();
    } catch (e) {
      if (!_isCurrent(gen)) return;
      await _abortSetup(e);
    }
  }

  Future<void> acceptIncoming() async {
    final current = session;
    if (current == null) return;
    final gen = _generation;
    final callId = current.id;
    final allowed = await requestPermissions(current.mediaType);
    if (!_isCurrent(gen) || session?.id != callId) return;
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
      if (!_isCurrent(gen) || session?.id != callId) return;
      session = await api.accept(token: tokenProvider(), callId: callId);
      phase = CallPhase.connecting;
      notifyListeners();
      _ringTimer?.cancel();
      final fresh = await api.get(token: tokenProvider(), callId: callId);
      if (!_isCurrent(gen) || session?.id != callId) return;
      session = fresh;
      if (fresh.sdpOffer != null && !_processedOffers.contains(fresh.sdpOffer)) {
        await media.applyRemoteOffer(fresh.sdpOffer!);
        _processedOffers.add(fresh.sdpOffer!);
        final answer = await media.createAnswer();
        session = await api.setAnswer(
          token: tokenProvider(),
          callId: callId,
          sdp: answer,
        );
        _processedAnswers.add(answer);
      }
      _startPollingIce();
    } catch (e) {
      if (!_isCurrent(gen)) return;
      await _abortSetup(e);
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
    if (_ending || phase == CallPhase.idle || phase == CallPhase.ended) return;
    _ending = true;
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

  /// Leaving the call surface ends the in-progress call.
  Future<void> onNavigationAway() async {
    if (phase == CallPhase.idle || phase == CallPhase.ended) return;
    await hangUp();
  }

  Future<void> onAppLifecycle(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        await reconcileActive();
      case AppLifecycleState.detached:
        await hangUp();
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
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

  /// Records an explicit safety-number comparison. Does not accept a new key.
  Future<void> markSafetyNumberVerified() async {
    final id = authenticatedPeerDeviceId;
    if (id == null || authPhase != CallAuthPhase.authenticated) return;
    await persistManualCallTrust(id);
    peerManuallyVerified = true;
    notifyListeners();
  }

  /// ICE restart or renegotiation that changes the remote DTLS fingerprint
  /// invalidates authentication. MVP does not silently re-sign.
  Future<void> onDtlsRestart(List<int> remoteFingerprint) async {
    final previous = _observedRemoteDtls;
    if (previous == null) return;
    if (previous.length == remoteFingerprint.length) {
      var diff = 0;
      for (var i = 0; i < previous.length; i++) {
        diff |= previous[i] ^ remoteFingerprint[i];
      }
      if (diff == 0) return;
    }
    authPhase = CallAuthPhase.failed;
    error = 'DTLS fingerprint changed';
    notifyListeners();
    await hangUp();
  }

  Future<void> _runAuth(int generation) async {
    final verify = authenticatePeer;
    final current = session;
    if (verify == null || current == null) return;
    authPhase = CallAuthPhase.verifying;
    notifyListeners();
    try {
      final fps = await media.dtlsFingerprints().timeout(authTimeout);
      if (!_isCurrent(generation) || session?.id != current.id) return;
      if (fps == null) {
        throw StateError('DTLS fingerprint unavailable');
      }
      _observedRemoteDtls = List<int>.from(fps.remote);
      final outcome = await verify(CallAuthRequest(
        session: current,
        myUserId: myUserId,
        localDtls: fps.local,
        remoteDtls: fps.remote,
      )).timeout(authTimeout);
      if (!_isCurrent(generation) || session?.id != current.id) return;
      authPhase = outcome.phase;
      peerFingerprintHex = outcome.fingerprintHex;
      authenticatedPeerDeviceId = outcome.peerDeviceId;
      peerManuallyVerified = outcome.manuallyVerified;
      if (outcome.phase != CallAuthPhase.authenticated) {
        error = outcome.error ?? 'Verification failed';
        notifyListeners();
        await hangUp();
        return;
      }
      notifyListeners();
      await media.setRemotePlaybackEnabled(true);
    } catch (e) {
      if (!_isCurrent(generation)) return;
      authPhase = CallAuthPhase.failed;
      error = e.toString();
      notifyListeners();
      await hangUp();
    }
  }

  void _beginCall() {
    _generation++;
    _ending = false;
    _mediaReleased = false;
    localMediaConnected = false;
    linkQuality = 'idle';
    authPhase = CallAuthPhase.idle;
    peerFingerprintHex = null;
    authenticatedPeerDeviceId = null;
    peerManuallyVerified = false;
    _observedRemoteDtls = null;
    _iceAfter = 0;
    _appliedIceSeq.clear();
    _processedAnswers.clear();
    _processedOffers.clear();
    _disconnectTimer?.cancel();
    phase = CallPhase.idle;
    session = null;
  }

  bool _isCurrent(int generation) => generation == _generation;

  void _applyAuthoritativeState(CallSession fresh, {required bool localConnection}) {
    if (fresh.state == CallRemoteState.ringing) {
      phase = fresh.callerUserId == myUserId
          ? CallPhase.outgoingRinging
          : CallPhase.incomingRinging;
      return;
    }
    // Server "connected" is a peer/client report, not proof this device has media.
    if (localConnection) {
      phase = CallPhase.connected;
      connectedAt ??= DateTime.now().toUtc();
      return;
    }
    phase = CallPhase.connecting;
  }

  Future<void> _abortSetup(Object e) async {
    error = e.toString();
    phase = CallPhase.failed;
    final id = session?.id;
    if (id != null) {
      try {
        await api.hangup(token: tokenProvider(), callId: id);
      } catch (_) {}
    }
    await _cleanupLocal(ended: true);
  }

  void _onRealtime(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    final callId = event['call_id'] as String?;
    if (type == null || callId == null) return;
    if (!type.startsWith('call.')) return;
    final gen = _generation;
    unawaited(_refreshFromServer(callId, gen));
  }

  Future<void> _refreshFromServer(String callId, int generation) async {
    try {
      final fresh = await api.get(token: tokenProvider(), callId: callId);
      if (!_isCurrent(generation)) return;
      if (session != null && session!.id != callId && phase != CallPhase.idle) {
        return;
      }
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
        if (!_isCurrent(generation)) return;
        _processedAnswers.add(fresh.sdpAnswer!);
        if (!localMediaConnected) phase = CallPhase.connecting;
      }
      _applyAuthoritativeState(fresh, localConnection: localMediaConnected);
      notifyListeners();
      await _pullIce();
    } catch (e) {
      if (!_isCurrent(generation)) return;
      error = e.toString();
      notifyListeners();
    }
  }

  void _onMediaEvent(CallMediaEvent event) {
    final gen = _generation;
    final callId = session?.id;
    switch (event.kind) {
      case CallMediaEventKind.localIce:
        if (callId == null || event.candidate == null) return;
        unawaited(_submitLocalIce(gen, callId, event));
      case CallMediaEventKind.connectionConnected:
        if (!_isCurrent(gen)) return;
        _disconnectTimer?.cancel();
        localMediaConnected = true;
        linkQuality = 'good';
        phase = CallPhase.connected;
        connectedAt ??= DateTime.now().toUtc();
        notifyListeners();
        if (callId != null) {
          unawaited(api.markConnected(token: tokenProvider(), callId: callId));
        }
        unawaited(media.setRemotePlaybackEnabled(false));
        if (authenticatePeer == null) {
          authPhase = CallAuthPhase.failed;
          error = 'Authentication unavailable';
          notifyListeners();
          unawaited(hangUp());
          return;
        }
        unawaited(_runAuth(gen));
      case CallMediaEventKind.connectionFailed:
        if (!_isCurrent(gen)) return;
        linkQuality = 'lost';
        error = 'Connection failed';
        phase = CallPhase.failed;
        notifyListeners();
        unawaited(hangUp());
      case CallMediaEventKind.connectionDisconnected:
        if (!_isCurrent(gen)) return;
        linkQuality = 'poor';
        _armDisconnectTimeout(gen);
      case CallMediaEventKind.remoteFingerprint:
        final fingerprint = event.dtlsFingerprint;
        if (fingerprint != null) unawaited(onDtlsRestart(fingerprint));
      case CallMediaEventKind.peerConnectionReplaced:
        if (!_isCurrent(gen) || session == null) return;
        if (phase == CallPhase.idle || phase == CallPhase.ended) return;
        authPhase = CallAuthPhase.failed;
        error = 'Peer connection replaced';
        notifyListeners();
        unawaited(hangUp());
    }
  }

  Future<void> _submitLocalIce(int generation, String callId, CallMediaEvent event) async {
    final attempts = iceSubmitAttempts < 1 ? 1 : iceSubmitAttempts;
    Object? last;
    for (var i = 0; i < attempts; i++) {
      if (!_isCurrent(generation) || session?.id != callId) return;
      try {
        await api.addIce(
          token: tokenProvider(),
          callId: callId,
          candidate: event.candidate!,
          clientIceId: event.clientIceId ?? 'ice-${DateTime.now().microsecondsSinceEpoch}',
          sdpMid: event.sdpMid,
          sdpMLineIndex: event.sdpMLineIndex,
        );
        return;
      } catch (e) {
        last = e;
        await Future<void>.delayed(Duration(milliseconds: 40 * (i + 1)));
      }
    }
    if (!_isCurrent(generation)) return;
    error = 'ICE submit failed: $last';
    notifyListeners();
  }

  void _armDisconnectTimeout(int generation) {
    _disconnectTimer?.cancel();
    _disconnectTimer = Timer(disconnectGrace, () {
      if (!_isCurrent(generation)) return;
      if (phase == CallPhase.idle || phase == CallPhase.ended) return;
      error = 'Connection lost';
      unawaited(hangUp());
    });
  }

  void _startPollingIce() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (phase == CallPhase.connected) notifyListeners();
      unawaited(_pullIce());
    });
  }

  Future<void> _pullIce() async {
    final id = session?.id;
    final gen = _generation;
    if (id == null) return;
    try {
      final items = await api.listIce(
        token: tokenProvider(),
        callId: id,
        after: _iceAfter,
      );
      if (!_isCurrent(gen) || session?.id != id) return;
      for (final ice in items) {
        if (_appliedIceSeq.contains(ice.seq)) {
          // Safe dedup: this seq was already applied on this call.
          if (ice.seq > _iceAfter) _iceAfter = ice.seq;
          continue;
        }
        await media.addRemoteIce(
          candidate: ice.candidate,
          sdpMid: ice.sdpMid,
          sdpMLineIndex: ice.sdpMLineIndex,
        );
        _appliedIceSeq.add(ice.seq);
        if (ice.seq > _iceAfter) _iceAfter = ice.seq;
      }
    } catch (_) {
      // Leave _iceAfter unchanged so the failed candidate is retried.
    }
  }

  void _armRingTimeout() {
    _ringTimer?.cancel();
    final gen = _generation;
    final expires = session?.ringExpiresAt;
    final wait = expires == null
        ? const Duration(seconds: 45)
        : expires.difference(DateTime.now().toUtc());
    _ringTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (!_isCurrent(gen)) return;
      if (phase == CallPhase.outgoingRinging || phase == CallPhase.incomingRinging) {
        unawaited(hangUp());
      }
    });
  }

  Future<void> _cleanupLocal({required bool ended}) async {
    _generation++;
    _poll?.cancel();
    _ringTimer?.cancel();
    _disconnectTimer?.cancel();
    if (!_mediaReleased) {
      _mediaReleased = true;
      await media.disposeMedia();
    }
    localMediaConnected = false;
    _ending = false;
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
    _appliedIceSeq.clear();
    notifyListeners();
    final endedGen = _generation;
    if (ended) {
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (phase == CallPhase.ended && _generation == endedGen) {
          phase = CallPhase.idle;
          session = null;
          _ending = false;
          notifyListeners();
        }
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ringTimer?.cancel();
    _disconnectTimer?.cancel();
    _rtSub?.cancel();
    _mediaSub?.cancel();
    if (!_mediaReleased) {
      _mediaReleased = true;
      unawaited(media.disposeMedia());
    }
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
