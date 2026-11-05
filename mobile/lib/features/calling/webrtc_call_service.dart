import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_service.dart';
import 'ice_servers.dart';
import 'models/call_session.dart';

/// Production WebRTC implementation using flutter_webrtc 1.6.3.
class WebRtcCallService implements CallService {
  WebRtcCallService({IceServerConfig? iceServers})
      : _iceServers = iceServers ?? const IceServerConfig();

  final IceServerConfig _iceServers;
  final _events = StreamController<CallMediaEvent>.broadcast();
  RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  MediaStream? _local;
  bool _renderersReady = false;
  int _iceSeq = 0;
  bool _videoActive = false;

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
      _prepare(enableVideo: enableVideo);

  @override
  Future<void> prepareIncoming({
    required CallMediaType mediaType,
    required bool enableVideo,
  }) =>
      _prepare(enableVideo: enableVideo);

  Future<void> _prepare({required bool enableVideo}) async {
    await disposeMedia();
    await _ensureRenderers();
    _pc = await createPeerConnection({
      'iceServers': _iceServers.toFlutterWebRtcIceServers(),
      if (_iceServers.relayOnly) 'iceTransportPolicy': 'relay',
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
          _events.add(const CallMediaEvent(kind: CallMediaEventKind.connectionConnected));
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _events.add(const CallMediaEvent(kind: CallMediaEventKind.connectionFailed));
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          _events.add(
              const CallMediaEvent(kind: CallMediaEventKind.connectionDisconnected));
        default:
          break;
      }
    };
    _pc!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams.first;
      }
    };

    _videoActive = false;
    if (enableVideo) {
      try {
        _local = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': {'facingMode': 'user'},
        });
        _videoActive = true;
      } catch (_) {
        // Camera failure: fall back to audio-only when supported.
        _local = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
      }
    } else {
      _local = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
    }
    _localRenderer.srcObject = _local;
    for (final track in _local!.getTracks()) {
      await _pc!.addTrack(track, _local!);
    }
  }

  @override
  Future<String> createOffer() async {
    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    await _pc!.setLocalDescription(offer);
    return offer.sdp ?? '';
  }

  @override
  Future<void> applyRemoteOffer(String sdp) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
  }

  @override
  Future<String> createAnswer() async {
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    return answer.sdp ?? '';
  }

  @override
  Future<void> applyRemoteAnswer(String sdp) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  @override
  Future<void> addRemoteIce({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) async {
    await _pc!.addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex));
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
  Future<void> disposeMedia() async {
    for (final track in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _local?.dispose();
    _local = null;
    await _pc?.close();
    _pc = null;
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    _videoActive = false;
    _iceSeq = 0;
    if (_renderersReady) {
      await _localRenderer.dispose();
      await _remoteRenderer.dispose();
      _localRenderer = RTCVideoRenderer();
      _remoteRenderer = RTCVideoRenderer();
      _renderersReady = false;
    }
  }
}
