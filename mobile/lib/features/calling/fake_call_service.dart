import 'dart:async';

import 'call_service.dart';
import 'models/call_session.dart';

/// In-memory WebRTC stand-in for controller/unit tests.
class FakeCallService implements CallService {
  final _events = StreamController<CallMediaEvent>.broadcast();
  String? remoteOffer;
  String? remoteAnswer;
  bool micMuted = false;
  bool speakerOn = false;
  bool cameraOn = true;
  int switches = 0;
  bool disposed = false;
  bool prepared = false;
  int prepareCount = 0;
  int disposeCount = 0;
  String? failCandidateContaining;
  final List<String> remoteIce = [];
  int applyAnswerCount = 0;

  @override
  Stream<CallMediaEvent> get events => _events.stream;

  @override
  Object? get localRenderer => null;

  @override
  Object? get remoteRenderer => null;

  void emit(CallMediaEvent event) {
    _events.add(event);
  }

  void emitConnected() {
    _events.add(const CallMediaEvent(kind: CallMediaEventKind.connectionConnected));
  }

  void emitFailed() {
    _events.add(const CallMediaEvent(kind: CallMediaEventKind.connectionFailed));
  }

  void emitLocalIce(String candidate) {
    _events.add(CallMediaEvent(
      kind: CallMediaEventKind.localIce,
      candidate: candidate,
      clientIceId: 'fake-${remoteIce.length + 1}',
      sdpMid: '0',
      sdpMLineIndex: 0,
    ));
  }

  @override
  Future<void> prepareOutgoing({
    required CallMediaType mediaType,
    required bool enableVideo,
  }) async {
    disposed = false;
    prepared = true;
    prepareCount++;
  }

  @override
  Future<void> prepareIncoming({
    required CallMediaType mediaType,
    required bool enableVideo,
  }) async {
    disposed = false;
    prepared = true;
    prepareCount++;
  }

  @override
  Future<String> createOffer() async => 'v=0\r\noffer-fake';

  @override
  Future<void> applyRemoteOffer(String sdp) async {
    remoteOffer = sdp;
  }

  @override
  Future<String> createAnswer() async => 'v=0\r\nanswer-fake';

  @override
  Future<void> applyRemoteAnswer(String sdp) async {
    remoteAnswer = sdp;
    applyAnswerCount++;
  }

  @override
  Future<void> addRemoteIce({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) async {
    if (failCandidateContaining != null &&
        candidate.contains(failCandidateContaining!)) {
      throw StateError('remote ice failed');
    }
    remoteIce.add(candidate);
  }

  @override
  Future<void> setMicrophoneMuted(bool muted) async {
    micMuted = muted;
  }

  @override
  Future<void> setSpeakerphone(bool enabled) async {
    speakerOn = enabled;
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    cameraOn = enabled;
  }

  @override
  Future<void> switchCamera() async {
    switches++;
  }

  @override
  Future<void> disposeMedia() async {
    disposeCount++;
    disposed = true;
    prepared = false;
  }

  Future<void> close() async {
    await _events.close();
  }
}
