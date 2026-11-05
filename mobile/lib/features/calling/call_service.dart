import 'models/call_session.dart';

/// Local media / peer-connection abstraction (no widgets).
abstract class CallService {
  Stream<CallMediaEvent> get events;

  Future<void> prepareOutgoing({
    required CallMediaType mediaType,
    required bool enableVideo,
  });

  Future<void> prepareIncoming({
    required CallMediaType mediaType,
    required bool enableVideo,
  });

  Future<String> createOffer();
  Future<void> applyRemoteOffer(String sdp);
  Future<String> createAnswer();
  Future<void> applyRemoteAnswer(String sdp);
  Future<void> addRemoteIce({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  });

  Future<void> setMicrophoneMuted(bool muted);
  Future<void> setSpeakerphone(bool enabled);
  Future<void> setCameraEnabled(bool enabled);
  Future<void> switchCamera();

  Object? get localRenderer;
  Object? get remoteRenderer;

  /// SHA-256 DTLS fingerprints from the local and remote descriptions.
  Future<({List<int> local, List<int> remote})?> dtlsFingerprints() async => null;

  /// Remote tracks stay disabled until authentication succeeds.
  Future<void> setRemotePlaybackEnabled(bool enabled) async {}

  Future<void> disposeMedia();
}

enum CallMediaEventKind {
  localIce,
  connectionConnected,
  connectionFailed,
  connectionDisconnected,
  remoteFingerprint,
  peerConnectionReplaced,
}

class CallMediaEvent {
  const CallMediaEvent({
    required this.kind,
    this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
    this.clientIceId,
    this.dtlsFingerprint,
  });

  final CallMediaEventKind kind;
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
  final String? clientIceId;
  final List<int>? dtlsFingerprint;
}
