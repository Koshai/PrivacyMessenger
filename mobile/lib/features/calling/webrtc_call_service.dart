import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../messaging/delivery_timing.dart';
import 'call_auth.dart';
import 'call_service.dart';
import 'ice_servers.dart';
import 'models/call_session.dart';

/// Production WebRTC implementation using flutter_webrtc 1.6.3.
class WebRtcCallService implements CallService {
  WebRtcCallService({
    this.loadIceConfig,
    IceServerConfig? iceServers,
    this.relayOnly = false,
  }) : _fallback = iceServers ?? const IceServerConfig();

  /// Fetches fresh short-lived ICE credentials for each new peer connection.
  final Future<IceServerConfig> Function()? loadIceConfig;
  final IceServerConfig _fallback;
  final bool relayOnly;
  final _events = StreamController<CallMediaEvent>.broadcast();
  RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  MediaStream? _local;
  MediaStream? _remoteStream;
  bool _remotePlayback = false;
  bool _renderersReady = false;
  int _iceSeq = 0;
  bool _videoActive = false;
  bool _tracksAttached = false;
  /// When set, local capture is in flight (incoming path) and must complete
  /// before tracks are attached after the remote offer.
  Future<void>? _captureFuture;
  int _mediaGeneration = 0;
  final List<RTCIceCandidate> _pendingRemoteIce = [];
  bool _remoteDescriptionReady = false;
  bool _connectedSignaled = false;

  @override
  Stream<CallMediaEvent> get events => _events.stream;

  @override
  Object? get localRenderer => _localRenderer;

  @override
  Object? get remoteRenderer => _remoteRenderer;

  bool get videoActive => _videoActive;

  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    _renderersReady = true;
  }

  @override
  Future<void> prepareOutgoing({
    required CallMediaType mediaType,
    required bool enableVideo,
  }) =>
      _prepare(enableVideo: enableVideo, attachTracksImmediately: true);

  @override
  Future<void> prepareIncoming({
    required CallMediaType mediaType,
    required bool enableVideo,
  }) =>
      _prepare(enableVideo: enableVideo, attachTracksImmediately: false);

  Future<IceServerConfig> _resolveIce() async {
    final loaded = loadIceConfig == null ? _fallback : await loadIceConfig!();
    final config = loaded.copyWith(relayOnly: relayOnly || loaded.relayOnly);
    if (config.unavailableReason != null) {
      throw StateError('TURN unavailable: ${config.unavailableReason}');
    }
    if (config.isExpired) {
      throw StateError('TURN credentials expired');
    }
    if (config.relayOnly && !config.hasTurn) {
      throw StateError('TURN unavailable');
    }
    return config;
  }

  Future<void> _prepare({
    required bool enableVideo,
    required bool attachTracksImmediately,
  }) async {
    final ice = await _resolveIce();
    if (_pc != null) {
      _events.add(const CallMediaEvent(kind: CallMediaEventKind.peerConnectionReplaced));
    }
    // Preserve remote ICE queued before Accept created a PC (ringing window).
    final preservedIce = List<RTCIceCandidate>.from(_pendingRemoteIce);
    await disposeMedia();
    _pendingRemoteIce.addAll(preservedIce);
    await _ensureRenderers();
    _connectedSignaled = false;
    _pc = await createPeerConnection({
      'iceServers': ice.toFlutterWebRtcIceServers(),
      if (ice.relayOnly) 'iceTransportPolicy': 'relay',
    });
    _pc!.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      _iceSeq++;
      _events.add(CallMediaEvent(
        kind: CallMediaEventKind.localIce,
        candidate: c.candidate,
        sdpMid: c.sdpMid,
        sdpMLineIndex: c.sdpMLineIndex,
        clientIceId: 'local-$_iceSeq',
      ));
    };
    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _signalConnected();
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _events.add(const CallMediaEvent(kind: CallMediaEventKind.connectionFailed));
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          _events.add(
              const CallMediaEvent(kind: CallMediaEventKind.connectionDisconnected));
        default:
          break;
      }
    };
    // Multi-m-line video calls on some Android builds report PC connection
    // state more reliably than iceConnectionState alone.
    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _signalConnected();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _events.add(const CallMediaEvent(kind: CallMediaEventKind.connectionFailed));
        default:
          break;
      }
    };
    _pc!.onTrack = (RTCTrackEvent event) {
      event.track.enabled = _remotePlayback;
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
      }
      for (final track in _remoteStream?.getTracks() ?? const <MediaStreamTrack>[]) {
        track.enabled = _remotePlayback;
      }
      if (_remotePlayback && _remoteStream != null) {
        _remoteRenderer.srcObject = _remoteStream;
      }
    };

    final gen = ++_mediaGeneration;
    if (attachTracksImmediately) {
      await _captureLocal(enableVideo: enableVideo, generation: gen);
      await _attachLocalTracks();
    } else {
      // Incoming: warm the camera while Accept/signaling continue, but do not
      // addTrack until after setRemoteDescription so Unified Plan m-lines match
      // the offer (video answerer ICE was stalling with pre-attached tracks).
      _captureFuture = _captureLocal(enableVideo: enableVideo, generation: gen);
      DeliveryTiming.record('call_media_capture_started', 0, detail: enableVideo ? 'video' : 'audio');
    }
  }

  void _signalConnected() {
    if (_connectedSignaled) return;
    _connectedSignaled = true;
    _events.add(const CallMediaEvent(kind: CallMediaEventKind.connectionConnected));
  }

  Future<void> _captureLocal({
    required bool enableVideo,
    required int generation,
  }) async {
    _videoActive = false;
    MediaStream stream;
    if (enableVideo) {
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': {'facingMode': 'user'},
        });
        if (generation != _mediaGeneration) {
          await _discardStream(stream);
          return;
        }
        _videoActive = true;
      } catch (_) {
        // Camera failure: fall back to audio-only when supported.
        stream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
        if (generation != _mediaGeneration) {
          await _discardStream(stream);
          return;
        }
      }
    } else {
      stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      if (generation != _mediaGeneration) {
        await _discardStream(stream);
        return;
      }
    }
    _local = stream;
    _localRenderer.srcObject = _local;
    DeliveryTiming.record(
      'call_media_capture_ready',
      0,
      detail: _videoActive ? 'video' : 'audio',
    );
  }

  Future<void> _discardStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  Future<void> _attachLocalTracks() async {
    final pc = _pc;
    final local = _local;
    if (pc == null || local == null || _tracksAttached) return;
    for (final track in local.getTracks()) {
      await pc.addTrack(track, local);
    }
    _tracksAttached = true;
  }

  @override
  Future<String> createOffer() async {
    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': 1,
      // Audio-only calls must not advertise a video transceiver the peer cannot
      // answer cleanly under a mic-only getUserMedia prepare.
      'offerToReceiveVideo': _videoActive ? 1 : 0,
    });
    // Local description must be the unmodified createOffer SDP. Sanitizing
    // before setLocalDescription left the PC in stable so answers failed with
    // "Called in wrong state: stable". Peer-side applyRemote* sanitizes.
    await _pc!.setLocalDescription(offer);
    return offer.sdp ?? '';
  }

  @override
  Future<void> applyRemoteOffer(String sdp) async {
    final cleaned = sanitizeCallSdp(sdp);
    await _pc!.setRemoteDescription(RTCSessionDescription(cleaned, 'offer'));
    _remoteDescriptionReady = true;
    final capture = _captureFuture;
    if (capture != null) {
      await capture;
      _captureFuture = null;
    }
    await _attachLocalTracks();
    await _flushPendingRemoteIce();
    await _noteRemoteFingerprint();
  }

  @override
  Future<String> createAnswer() async {
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    return answer.sdp ?? '';
  }

  @override
  Future<void> applyRemoteAnswer(String sdp) async {
    final cleaned = sanitizeCallSdp(sdp);
    await _pc!.setRemoteDescription(RTCSessionDescription(cleaned, 'answer'));
    _remoteDescriptionReady = true;
    await _flushPendingRemoteIce();
    await _noteRemoteFingerprint();
  }

  @override
  Future<void> addRemoteIce({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) async {
    final ice = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
    final pc = _pc;
    // Always queue until a live PC has a remote description. Dropping while
    // pc==null permanently loses early caller candidates (video Accept is slow
    // enough that ICE often arrives during ringing).
    if (pc == null || !_remoteDescriptionReady) {
      _pendingRemoteIce.add(ice);
      return;
    }
    await pc.addCandidate(ice);
  }

  Future<void> _flushPendingRemoteIce() async {
    final pc = _pc;
    if (pc == null) return;
    final pending = List<RTCIceCandidate>.from(_pendingRemoteIce);
    _pendingRemoteIce.clear();
    for (final ice in pending) {
      await pc.addCandidate(ice);
    }
  }

  @override
  Future<void> setMicrophoneMuted(bool muted) async {
    for (final track in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> setSpeakerphone(bool enabled) async {
    await Helper.setSpeakerphoneOn(enabled);
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    for (final track in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  Future<void> switchCamera() async {
    final tracks = _local?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    await Helper.switchCamera(tracks.first);
  }

  @override
  Future<void> setRemotePlaybackEnabled(bool enabled) async {
    _remotePlayback = enabled;
    for (final track in _remoteStream?.getTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
    if (_renderersReady) {
      _remoteRenderer.srcObject = enabled ? _remoteStream : null;
    }
  }

  Future<void> _noteRemoteFingerprint() async {
    final remote = parseSdpFingerprint((await _pc?.getRemoteDescription())?.sdp);
    if (remote == null) return;
    _events.add(CallMediaEvent(
      kind: CallMediaEventKind.remoteFingerprint,
      dtlsFingerprint: remote,
    ));
  }

  @override
  Future<({List<int> local, List<int> remote})?> dtlsFingerprints() async {
    // Brief retry: descriptions are set before ICE Connected, but some devices
    // briefly return null mid renegotiation for multi-m-line video SDP.
    for (var i = 0; i < 5; i++) {
      final local = parseSdpFingerprint((await _pc?.getLocalDescription())?.sdp);
      final remote = parseSdpFingerprint((await _pc?.getRemoteDescription())?.sdp);
      if (local != null && remote != null) {
        return (local: local, remote: remote);
      }
      await Future<void>.delayed(Duration(milliseconds: 40 * (i + 1)));
    }
    return null;
  }

  @override
  Future<void> disposeMedia() async {
    _mediaGeneration++;
    _captureFuture = null;
    for (final track in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _local?.dispose();
    _local = null;
    await _pc?.close();
    _pc = null;
    _remoteStream = null;
    _remotePlayback = false;
    _videoActive = false;
    _tracksAttached = false;
    _connectedSignaled = false;
    _iceSeq = 0;
    _pendingRemoteIce.clear();
    _remoteDescriptionReady = false;
    // flutter_webrtc rejects srcObject until initialize(); prepare calls
    // disposeMedia before the first _ensureRenderers, so guard the clear.
    if (_renderersReady) {
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
      await _localRenderer.dispose();
      await _remoteRenderer.dispose();
      _localRenderer = RTCVideoRenderer();
      _remoteRenderer = RTCVideoRenderer();
      _renderersReady = false;
    }
  }
}

/// Normalizes SDP so Unified Plan setRemoteDescription accepts offers from
/// peers that still emit Plan-B SSRC attribute lines.
///
/// Device evidence (Samsung arm64): `a=ssrc:<id> msid:<stream> <track>` is
/// rejected as "Invalid SDP line", aborting Accept before an answer is posted.
/// Media-level `a=msid:` already carries the association under Unified Plan.
String sanitizeCallSdp(String sdp) {
  if (sdp.isEmpty) return sdp;
  final normalized = sdp.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final planBSsrc = RegExp(
    r'^a=ssrc:\d+\s+(msid|mslabel|label):',
    caseSensitive: false,
  );
  final kept = <String>[];
  for (final raw in normalized.split('\n')) {
    final line = raw.trimRight();
    if (planBSsrc.hasMatch(line)) continue;
    kept.add(line);
  }
  while (kept.isNotEmpty && kept.last.isEmpty) {
    kept.removeLast();
  }
  return '${kept.join('\r\n')}\r\n';
}
