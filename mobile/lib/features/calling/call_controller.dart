import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/network/api_client.dart';
import '../messaging/delivery_timing.dart';
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
    this.warmCallAuth,
    this.authTimeout = const Duration(seconds: 45),
    this.recheckEnrollment,
    this.clearLocalSecrets,
    this.enrollmentTimeout = const Duration(seconds: 5),
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

  /// Prefetch call-auth key material during prepare so hello is not blocked by
  /// secure-storage latency after ICE Connected (video encoder load).
  final Future<void> Function()? warmCallAuth;
  final Duration authTimeout;

  /// Production rechecks enrollment while a call is up. Null in unit tests
  /// that do not model revocation. A false result ends the call.
  final Future<bool> Function(String peerUserId, String peerDeviceId)? recheckEnrollment;
  final Future<void> Function()? clearLocalSecrets;
  final Duration enrollmentTimeout;

  /// True after an enrollment request timed out or the API could not be reached.
  /// A deferred check does not end the call. A false result does.
  bool enrollmentRecheckDeferred = false;

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
  Timer? _endedIdleTimer;
  int _generation = 0;
  bool _ending = false;
  bool _mediaReleased = false;
  bool _disposed = false;
  bool _rechecking = false;
  int? _authGeneration;

  /// Local/remote SDP must both be applied before ICE Failed/Disconnected are
  /// terminal. Premature Failed during gather-before-answer was ending calls
  /// ~75ms after Accept (server end_reason=hangup, no answer posted).
  bool _localDescriptionSet = false;
  bool _remoteDescriptionSet = false;

  /// Local ICE gathered during createOffer-before-initiate (no call id yet).
  final List<CallMediaEvent> _pendingLocalIce = [];

  bool get _sdpPairReady {
    if (_localDescriptionSet && _remoteDescriptionSet) return true;
    final s = session;
    if (s == null) return false;
    // Server already holding both SDPs means negotiation completed even if the
    // local flags were reset (tests, reconcile). Offer-only must stay non-terminal.
    return (s.sdpOffer?.isNotEmpty ?? false) && (s.sdpAnswer?.isNotEmpty ?? false);
  }

  /// Privacy-safe auth failure tag for DeliveryTiming (no fingerprints/ids).
  static String _authFailDetail(String phase, String? error) {
    final e = (error ?? '').toLowerCase();
    if (e.contains('timed out')) return 'peer_hello_timeout';
    if (e.contains('binding channel')) return 'binding_channel';
    if (e.contains('not bound to this call')) return 'peer_device_unbound';
    if (e.contains('no mls-authenticated')) return 'binding_missing';
    if (e.contains('pin is corrupt')) return 'pin_corrupt';
    if (e.contains('hello identity')) return 'hello_mls_mismatch';
    if (e.contains('enrollment check')) return 'enrollment_unavailable';
    if (e.contains('revoked')) return 'revoked';
    if (e.contains('confirmation missing')) return 'confirm_missing';
    if (e.contains('authentication failed')) return 'confirm_failed';
    if (e.contains('fingerprint unavailable')) return 'dtls_unavailable';
    if (e.contains('malformed')) return 'malformed';
    if (e.contains('signature')) return 'bad_signature';
    if (e.contains('identity changed') || phase == CallAuthPhase.identityChanged) {
      return 'identity_changed';
    }
    if (e.contains('replay')) return 'replay';
    if (e.contains('mismatch')) return 'mismatch';
    if (e.contains('unbound') || e.contains('not bound to the pinned')) return 'unbound';
    if (e.contains('messaging identity')) return 'no_local_identity';
    if (e.contains('history is not available')) return 'no_pipeline';
    return phase;
  }

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
      unawaited(_warmAuth());
      // Block re-entrancy and allow hangUp while createOffer runs (video capture
      // can take seconds). Do not arm the ring timer until the server call exists.
      phase = CallPhase.outgoingRinging;
      notifyListeners();
      // Build the local offer before initiate so the callee cannot Accept into a
      // ringing call that still has no SDP (video createOffer is slow enough to
      // lose that race → missing_remote_offer StateError on Accept).
      final offer = await media.createOffer();
      if (!_isCurrent(gen)) return;
      if (offer.trim().isEmpty) {
        throw StateError('empty_local_offer');
      }
      _localDescriptionSet = true;
      DeliveryTiming.record('call_local_offer_ready', 0);
      final clientId = 'c-${DateTime.now().microsecondsSinceEpoch}';
      session = await api.initiate(
        token: tokenProvider(),
        calleeUserId: peerUserId,
        mediaType: mediaType,
        clientCallId: clientId,
      );
      if (!_isCurrent(gen) || session == null) return;
      await _flushPendingLocalIce(gen, session!.id);
      session = await api.setOffer(
        token: tokenProvider(),
        callId: session!.id,
        sdp: offer,
      );
      _processedOffers.add(offer);
      if (!_isCurrent(gen)) return;
      _armRingTimeout();
      _startPollingIce();
    } catch (e) {
      if (!_isCurrent(gen)) return;
      DeliveryTiming.record(
        'call_offer_abort',
        0,
        detail: _shortErrorDetail(e),
      );
      await _abortSetup(e);
    }
  }

  Future<void> acceptIncoming() async {
    final current = session;
    if (current == null) return;
    final gen = _generation;
    final callId = current.id;
    DeliveryTiming.record('call_accept_tap', 0);
    // Disarm ring timeout before any await so Accept cannot race HangUp.
    _ringTimer?.cancel();
    final allowed = await requestPermissions(current.mediaType);
    if (!_isCurrent(gen) || session?.id != callId) return;
    if (!allowed) {
      error = 'Permission denied';
      phase = CallPhase.failed;
      notifyListeners();
      return;
    }
    // Leave incomingRinging before prepare so a late ring timer cannot hang up.
    phase = CallPhase.connecting;
    notifyListeners();
    final span = DeliveryTiming.start();
    try {
      await media.prepareIncoming(
        mediaType: current.mediaType,
        enableVideo: current.mediaType == CallMediaType.video,
      );
      span.lap('call_accept_prepare');
      if (!_isCurrent(gen) || session?.id != callId) return;
      // PC now exists: re-pull any candidates that arrived during ringing (they
      // were intentionally not applied / not cursor-advanced while unprepared).
      unawaited(_warmAuth());
      _iceAfter = 0;
      _appliedIceSeq.clear();
      session = await api.accept(token: tokenProvider(), callId: callId);
      span.lap('call_accept_api');
      if (!_isCurrent(gen) || session?.id != callId) return;
      notifyListeners();
      var fresh = await api.get(token: tokenProvider(), callId: callId);
      span.lap('call_accept_get');
      if (!_isCurrent(gen) || session?.id != callId) return;
      session = fresh;
      if (fresh.isEnded) {
        DeliveryTiming.record('call_accept_already_ended', 0);
        await _cleanupLocal(ended: true);
        return;
      }
      // Brief wait for the caller's setOffer to land (defense in depth if the
      // peer still posts the offer after initiate).
      var offer = fresh.sdpOffer;
      // Up to ~5s: caller setOffer can lag initiate on slow links after video
      // createOffer-before-initiate (still observed missing_remote_offer once).
      for (var i = 0; i < 50 && (offer == null || offer.isEmpty); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!_isCurrent(gen) || session?.id != callId) return;
        fresh = await api.get(token: tokenProvider(), callId: callId);
        session = fresh;
        if (fresh.isEnded) {
          DeliveryTiming.record('call_accept_already_ended', 0);
          await _cleanupLocal(ended: true);
          return;
        }
        offer = fresh.sdpOffer;
      }
      if (offer == null || offer.isEmpty) {
        throw StateError('missing_remote_offer');
      }
      if (!_processedOffers.contains(offer)) {
        await media.applyRemoteOffer(offer);
        _remoteDescriptionSet = true;
        _processedOffers.add(offer);
        span.lap('call_accept_remote_offer');
        final answer = await media.createAnswer();
        if (answer.trim().isEmpty) {
          throw StateError('empty_local_answer');
        }
        _localDescriptionSet = true;
        span.lap('call_accept_create_answer');
        session = await api.setAnswer(
          token: tokenProvider(),
          callId: callId,
          sdp: answer,
        );
        _processedAnswers.add(answer);
        span.lap('call_accept_set_answer');
      }
      await _pullIce();
      _startPollingIce();
      // DTLS fingerprints live in SDP; start MLS hello while ICE gathers so
      // video peers are not racing a 10s hello window after ICE Connected.
      if (_sdpPairReady) {
        unawaited(_runAuth(gen));
      }
      span.total('call_accept_total');
    } catch (e) {
      if (!_isCurrent(gen)) return;
      DeliveryTiming.record(
        'call_accept_abort',
        0,
        detail: _shortErrorDetail(e),
      );
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
    DeliveryTiming.record('call_local_end', 0, detail: 'cancel');
    if (id == null) {
      // Pre-initiate cancel (createOffer still running): release local media only.
      await _cleanupLocal(ended: true);
      return;
    }
    try {
      session = await api.cancel(token: tokenProvider(), callId: id);
    } finally {
      await _cleanupLocal(ended: true);
    }
  }

  Future<void> hangUp({String reason = 'hangup'}) async {
    if (_ending || phase == CallPhase.idle || phase == CallPhase.ended) return;
    _ending = true;
    DeliveryTiming.record('call_local_end', 0, detail: reason);
    final id = session?.id;
    if (id != null) {
      try {
        session = await api.hangup(token: tokenProvider(), callId: id);
      } catch (_) {}
    }
    await _cleanupLocal(ended: true);
  }

  Future<void> onLogout() async {
    await hangUp(reason: 'logout');
    final clear = clearLocalSecrets;
    if (clear != null) await clear();
  }

  /// Leaving the call surface ends the in-progress call.
  Future<void> onNavigationAway() async {
    if (phase == CallPhase.idle || phase == CallPhase.ended) return;
    await hangUp(reason: 'navigation_away');
  }

  Future<void> onAppLifecycle(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        await reconcileActive();
        await recheckPeerIdentity();
      case AppLifecycleState.detached:
        await hangUp(reason: 'app_detached');
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  /// Ends the call when the pinned peer is no longer enrolled.
  /// Cryptographic verification stays on the client; this is the revocation signal.
  Future<void> recheckPeerIdentity() async {
    final check = recheckEnrollment;
    final peer = authenticatedPeerDeviceId;
    final current = session;
    if (check == null || peer == null || current == null || _rechecking) return;
    if (authPhase != CallAuthPhase.authenticated) return;
    final generation = _generation;
    _rechecking = true;
    try {
      final peerUser =
          current.callerUserId == myUserId ? current.calleeUserId : current.callerUserId;
      final bool ok;
      try {
        ok = await check(peerUser, peer).timeout(enrollmentTimeout);
      } on TimeoutException {
        enrollmentRecheckDeferred = true;
        return;
      } catch (_) {
        enrollmentRecheckDeferred = true;
        return;
      }
      if (!_isCurrent(generation) || session?.id != current.id) return;
      if (authPhase != CallAuthPhase.authenticated) return;
      if (!ok) {
        enrollmentRecheckDeferred = false;
        authPhase = CallAuthPhase.failed;
        error = 'Identity revoked';
        notifyListeners();
        await hangUp(reason: 'identity_revoked');
        return;
      }
      enrollmentRecheckDeferred = false;
    } finally {
      _rechecking = false;
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
  ///
  /// Only compares against the fingerprint pinned during this call's auth.
  /// A leftover pin from a prior call must not end the next Accept (video
  /// accept was hanging up with dtls_restart immediately after applyRemoteOffer).
  Future<void> onDtlsRestart(List<int> remoteFingerprint) async {
    if (authPhase != CallAuthPhase.authenticated) return;
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
    await hangUp(reason: 'dtls_restart');
  }

  bool _playbackAllowed(int generation, String callId) {
    return _isCurrent(generation) &&
        !_mediaReleased &&
        session?.id == callId &&
        authPhase == CallAuthPhase.authenticated &&
        localMediaConnected &&
        phase != CallPhase.ended &&
        phase != CallPhase.idle &&
        phase != CallPhase.failed;
  }

  Future<void> _warmAuth() async {
    final warm = warmCallAuth;
    if (warm == null) return;
    try {
      await warm();
      DeliveryTiming.record('call_auth_warm_ok', 0);
    } catch (_) {
      DeliveryTiming.record('call_auth_warm_failed', 0);
    }
  }

  Future<void> _runAuth(int generation) async {
    final verify = authenticatePeer;
    final current = session;
    if (verify == null || current == null || _mediaReleased) return;
    if (_authGeneration == generation) return;
    _authGeneration = generation;
    authPhase = CallAuthPhase.verifying;
    notifyListeners();
    DeliveryTiming.record('call_auth_start', 0);
    try {
      // Publish hello immediately; resolve DTLS only when confirm needs it.
      // Waiting on dtlsFingerprints before hello made video peers hit
      // peer_hello_timeout while the other side was still reading SDP.
      final outcome = await verify(CallAuthRequest(
        session: current,
        myUserId: myUserId,
        resolveDtls: () async {
          final fps = await media.dtlsFingerprints().timeout(authTimeout);
          if (fps == null) {
            throw StateError('DTLS fingerprint unavailable');
          }
          _observedRemoteDtls = List<int>.from(fps.remote);
          return fps;
        },
      )).timeout(authTimeout);
      if (!_isCurrent(generation) || session?.id != current.id || _mediaReleased) return;
      if (phase == CallPhase.ended || phase == CallPhase.idle || phase == CallPhase.failed) return;
      authPhase = outcome.phase;
      peerFingerprintHex = outcome.fingerprintHex;
      authenticatedPeerDeviceId = outcome.peerDeviceId;
      peerManuallyVerified = outcome.manuallyVerified;
      if (outcome.phase != CallAuthPhase.authenticated) {
        error = outcome.error ?? 'Verification failed';
        DeliveryTiming.record(
          'call_auth_failed',
          0,
          detail: _authFailDetail(outcome.phase, outcome.error),
        );
        notifyListeners();
        await hangUp(reason: 'auth_failed');
        return;
      }
      // Ensure mid-call DTLS restart detection has a pin even when the
      // authenticator did not invoke resolveDtls (test fakes / short-circuit).
      if (_observedRemoteDtls == null) {
        final fps = await media.dtlsFingerprints();
        if (fps != null) {
          _observedRemoteDtls = List<int>.from(fps.remote);
        }
      }
      DeliveryTiming.record('call_auth_ok', 0);
      notifyListeners();
      if (!_playbackAllowed(generation, current.id)) return;
      await media.setRemotePlaybackEnabled(true);
      if (!_playbackAllowed(generation, current.id)) {
        await media.setRemotePlaybackEnabled(false);
      }
    } catch (e) {
      if (!_isCurrent(generation) || _mediaReleased) return;
      authPhase = CallAuthPhase.failed;
      error = e.toString();
      DeliveryTiming.record(
        'call_auth_failed',
        0,
        detail: _authExceptionDetail(e),
      );
      notifyListeners();
      await hangUp(reason: 'auth_exception');
    }
  }

  static String _authExceptionDetail(Object e) {
    if (e is ApiException) {
      final code = e.statusCode;
      return code == null ? 'api_${e.kind.name}' : 'api_${e.kind.name}_$code';
    }
    final s = e.toString();
    if (s.contains('TimeoutException')) return 'TimeoutException';
    return e.runtimeType.toString();
  }

  /// Privacy-safe abort tag: type plus a short stable message token.
  static String _shortErrorDetail(Object e) {
    if (e is StateError) {
      final msg = e.message;
      if (msg.contains('missing_remote_offer')) return 'missing_remote_offer';
      if (msg.contains('empty_local_offer')) return 'empty_local_offer';
      if (msg.contains('empty_local_answer')) return 'empty_local_answer';
      return 'StateError';
    }
    return e.runtimeType.toString();
  }

  void _beginCall() {
    _generation++;
    _ending = false;
    _mediaReleased = false;
    localMediaConnected = false;
    _localDescriptionSet = false;
    _remoteDescriptionSet = false;
    _pendingLocalIce.clear();
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
    _authGeneration = null;
    enrollmentRecheckDeferred = false;
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
    // Accepted/connected leaves the ring window; disarm so a late timer cannot
    // hang up a call that the peer already accepted.
    _ringTimer?.cancel();
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
        _remoteDescriptionSet = true;
        _processedAnswers.add(fresh.sdpAnswer!);
        if (!localMediaConnected) phase = CallPhase.connecting;
        DeliveryTiming.record('call_remote_answer_applied', 0);
        // Start hello as soon as both SDPs exist (fingerprints are in SDP).
        unawaited(_runAuth(generation));
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
        if (event.candidate == null) return;
        if (callId == null) {
          // createOffer-before-initiate gathers ICE before the server call exists.
          _pendingLocalIce.add(event);
          return;
        }
        unawaited(_submitLocalIce(gen, callId, event));
      case CallMediaEventKind.connectionConnected:
        if (!_isCurrent(gen) || _mediaReleased) return;
        if (phase == CallPhase.ended || phase == CallPhase.idle || phase == CallPhase.failed) return;
        _disconnectTimer?.cancel();
        localMediaConnected = true;
        linkQuality = 'good';
        phase = CallPhase.connected;
        connectedAt ??= DateTime.now().toUtc();
        DeliveryTiming.record('call_ice_connected', 0);
        notifyListeners();
        if (callId != null) {
          unawaited(api.markConnected(token: tokenProvider(), callId: callId));
        }
        unawaited(media.setRemotePlaybackEnabled(false));
        if (authenticatePeer == null) {
          authPhase = CallAuthPhase.failed;
          error = 'Authentication unavailable';
          DeliveryTiming.record('call_auth_failed', 0, detail: 'missing_authenticator');
          notifyListeners();
          unawaited(hangUp(reason: 'missing_authenticator'));
          return;
        }
        if (authPhase == CallAuthPhase.authenticated && callId != null) {
          // Auth completed during SDP/ICE gather; unlock playback now that
          // the transport is up.
          unawaited(media.setRemotePlaybackEnabled(true));
        } else {
          unawaited(_runAuth(gen));
        }
      case CallMediaEventKind.connectionFailed:
        if (!_isCurrent(gen)) return;
        // Gathering/allocate failures before both SDPs exist are not terminal.
        if (!_sdpPairReady) {
          DeliveryTiming.record('call_ice_failed_ignored', 0, detail: 'pre_sdp');
          return;
        }
        linkQuality = 'lost';
        error = 'Connection failed';
        phase = CallPhase.failed;
        notifyListeners();
        unawaited(hangUp(reason: 'ice_failed'));
      case CallMediaEventKind.connectionDisconnected:
        if (!_isCurrent(gen)) return;
        if (!_sdpPairReady) {
          DeliveryTiming.record(
            'call_ice_disconnected_ignored',
            0,
            detail: 'pre_sdp',
          );
          return;
        }
        linkQuality = 'poor';
        _armDisconnectTimeout(gen);
      case CallMediaEventKind.remoteFingerprint:
        final fingerprint = event.dtlsFingerprint;
        if (fingerprint != null) unawaited(onDtlsRestart(fingerprint));
      case CallMediaEventKind.peerConnectionReplaced:
        if (!_isCurrent(gen) || session == null) return;
        if (phase == CallPhase.idle || phase == CallPhase.ended) return;
        // Intentional PC rebuild during prepare emits this before SDPs exist.
        if (!_sdpPairReady) {
          DeliveryTiming.record(
            'call_pc_replaced_ignored',
            0,
            detail: 'pre_sdp',
          );
          return;
        }
        authPhase = CallAuthPhase.failed;
        error = 'Peer connection replaced';
        notifyListeners();
        unawaited(hangUp(reason: 'pc_replaced'));
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
      unawaited(hangUp(reason: 'disconnect_timeout'));
    });
  }

  void _startPollingIce() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (phase == CallPhase.connected) notifyListeners();
      unawaited(_pullIce());
      if (authPhase == CallAuthPhase.authenticated) {
        unawaited(recheckPeerIdentity());
      }
    });
  }

  Future<void> _flushPendingLocalIce(int generation, String callId) async {
    if (_pendingLocalIce.isEmpty) return;
    final pending = List<CallMediaEvent>.from(_pendingLocalIce);
    _pendingLocalIce.clear();
    for (final event in pending) {
      if (!_isCurrent(generation) || session?.id != callId) return;
      await _submitLocalIce(generation, callId, event);
    }
  }

  Future<void> _pullIce() async {
    final id = session?.id;
    final gen = _generation;
    if (id == null) return;
    // During incomingRinging the PC does not exist yet. Applying (or even
    // cursor-advancing past) early caller candidates permanently breaks video
    // ICE when Accept is delayed by camera warm-up.
    if (phase == CallPhase.incomingRinging) return;
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
        unawaited(hangUp(reason: 'ring_timeout'));
      }
    });
  }

  Future<void> _cleanupLocal({required bool ended}) async {
    _generation++;
    _poll?.cancel();
    _ringTimer?.cancel();
    _disconnectTimer?.cancel();
    _endedIdleTimer?.cancel();
    if (!_mediaReleased) {
      _mediaReleased = true;
      await media.disposeMedia();
    }
    localMediaConnected = false;
    _localDescriptionSet = false;
    _remoteDescriptionSet = false;
    _pendingLocalIce.clear();
    authPhase = CallAuthPhase.idle;
    authenticatedPeerDeviceId = null;
    peerFingerprintHex = null;
    peerManuallyVerified = false;
    _observedRemoteDtls = null;
    _authGeneration = null;
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
    if (!_disposed) notifyListeners();
    final endedGen = _generation;
    if (ended) {
      _endedIdleTimer = Timer(const Duration(milliseconds: 400), () {
        if (_disposed) return;
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
    _disposed = true;
    _poll?.cancel();
    _ringTimer?.cancel();
    _disconnectTimer?.cancel();
    _endedIdleTimer?.cancel();
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
