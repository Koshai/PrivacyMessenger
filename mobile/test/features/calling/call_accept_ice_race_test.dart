import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';

Map<String, dynamic> _sessionJson({
  String id = 'call-1',
  String state = 'ringing',
  String? offer,
  String? answer,
}) {
  return {
    'id': id,
    'caller_user_id': 'alice',
    'callee_user_id': 'bob',
    'caller_device_id': 'adev',
    'media_type': 'audio',
    'state': state,
    'client_call_id': 'c1',
    'ring_expires_at':
        DateTime.now().toUtc().add(const Duration(minutes: 1)).toIso8601String(),
    'created_at': DateTime.now().toUtc().toIso8601String(),
    'updated_at': DateTime.now().toUtc().toIso8601String(),
    'version': 1,
    'sdp_offer': ?offer,
    'sdp_answer': ?answer,
  };
}

CallController _bob({
  required FakeCallService media,
  required MockClient client,
  Stream<Map<String, dynamic>>? hints,
}) {
  return CallController(
    api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
    media: media,
    myUserId: 'bob',
    tokenProvider: () => 'tok',
    hintEvents: hints,
    requestPermissions: (_) async => true,
    authenticatePeer: (_) async =>
        const CallAuthOutcome(phase: CallAuthPhase.authenticated),
  );
}

void main() {
  test('ICE Failed before SDP pair is ready does not hang up', () async {
    var hangups = 0;
    final media = FakeCallService();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/hangup')) {
        hangups++;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      if (request.url.path == '/calls/active') {
        return http.Response(
          jsonEncode({'call': _sessionJson(state: 'accepted', offer: 'v=0\r\noffer')}),
          200,
        );
      }
      if (request.url.path.endsWith('/ice')) {
        return http.Response(jsonEncode({'candidates': []}), 200);
      }
      return http.Response('nope', 404);
    });
    final controller = _bob(media: media, client: client);
    addTearDown(controller.dispose);
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(
      _sessionJson(state: 'accepted', offer: 'v=0\r\noffer'),
    );
    await controller.startListening();

    media.emitFailed();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(hangups, 0, reason: 'pre-SDP ICE Failed must not end the call');
    expect(media.disposed, isFalse);
    expect(controller.phase, CallPhase.connecting);
  });

  test('Accept completes answer even if ICE Failed fires during prepare', () async {
    var hangups = 0;
    var answers = 0;
    final prepareGate = Completer<void>();
    final media = _DelayedPrepareFake(prepareGate);
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'POST' && path.endsWith('/accept')) {
        return http.Response(
          jsonEncode(_sessionJson(state: 'accepted', offer: 'v=0\r\noffer-fake')),
          200,
        );
      }
      if (request.method == 'GET' && path.endsWith('/calls/call-1')) {
        return http.Response(
          jsonEncode(_sessionJson(state: 'accepted', offer: 'v=0\r\noffer-fake')),
          200,
        );
      }
      if (request.method == 'PUT' && path.endsWith('/answer')) {
        answers++;
        return http.Response(
          jsonEncode(_sessionJson(
            state: 'accepted',
            offer: 'v=0\r\noffer-fake',
            answer: 'v=0\r\nanswer-fake',
          )),
          200,
        );
      }
      if (path.endsWith('/hangup')) {
        hangups++;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      if (path.endsWith('/ice')) {
        return http.Response(jsonEncode({'candidates': []}), 200);
      }
      return http.Response('nope', 404);
    });

    final controller = _bob(media: media, client: client);
    addTearDown(controller.dispose);
    controller.phase = CallPhase.incomingRinging;
    controller.session = CallSession.fromJson(
      _sessionJson(state: 'ringing', offer: 'v=0\r\noffer-fake'),
    );
    await controller.startListening();

    final acceptFuture = controller.acceptIncoming();
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, CallPhase.connecting);
    media.emitFailed();
    prepareGate.complete();
    await acceptFuture;

    expect(answers, 1);
    expect(hangups, 0);
    expect(controller.phase, CallPhase.connecting);
    expect(media.remoteOffer, 'v=0\r\noffer-fake');
    expect(media.disposed, isFalse);
  });

  test('post-negotiation ICE Failed hangs up', () async {
    var hangups = 0;
    var state = 'accepted';
    final media = FakeCallService();
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'POST' && path == '/calls') {
        return http.Response(jsonEncode(_sessionJson()), 201);
      }
      if (request.method == 'PUT' && path.endsWith('/offer')) {
        return http.Response(
          jsonEncode(_sessionJson(offer: 'v=0\r\noffer-fake')),
          200,
        );
      }
      if (path == '/calls/active') {
        return http.Response(
          jsonEncode({
            'call': _sessionJson(
              state: state,
              offer: 'v=0\r\noffer-fake',
              answer: state == 'ended' ? null : 'v=0\r\nanswer-fake',
            ),
          }),
          200,
        );
      }
      if (path.endsWith('/calls/call-1')) {
        return http.Response(
          jsonEncode(_sessionJson(
            state: state,
            offer: 'v=0\r\noffer-fake',
            answer: state == 'ended' ? null : 'v=0\r\nanswer-fake',
          )),
          200,
        );
      }
      if (path.endsWith('/hangup')) {
        hangups++;
        state = 'ended';
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      if (path.endsWith('/ice')) {
        return http.Response(jsonEncode({'candidates': []}), 200);
      }
      return http.Response('nope', 404);
    });

    final hints = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(hints.close);
    final controller = CallController(
      api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
      media: media,
      myUserId: 'alice',
      tokenProvider: () => 'tok',
      hintEvents: hints.stream,
      requestPermissions: (_) async => true,
      authenticatePeer: (_) async =>
          const CallAuthOutcome(phase: CallAuthPhase.authenticated),
    );
    addTearDown(controller.dispose);

    await controller.startOutgoing(
      peerUserId: 'bob',
      mediaType: CallMediaType.audio,
    );
    expect(controller.phase, CallPhase.outgoingRinging);

    media.emitFailed();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(hangups, 0, reason: 'still waiting for answer');

    // Subscribe after the pre-answer Failed check so /calls/active (which
    // already includes the answer) cannot make _sdpPairReady true early.
    await controller.startListening();
    hints.add({'type': 'call.answer', 'call_id': 'call-1'});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(media.applyAnswerCount, 1);

    media.emitFailed();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(hangups, 1);
  });

  test('early remote ICE during ringing is applied after Accept prepare', () async {
    // Regression 19.7.26B: video caller ICE arrives while callee is still
    // ringing; applying/cursor-advancing before prepare left the callee without
    // ice_connected and the caller hit peer_hello_timeout.
    final media = FakeCallService();
    var iceListCalls = 0;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/calls/call-1') {
        return http.Response(
          jsonEncode(_sessionJson(state: 'ringing', offer: 'v=0\r\noffer-fake')),
          200,
        );
      }
      if (path.endsWith('/accept')) {
        return http.Response(
          jsonEncode(_sessionJson(state: 'accepted', offer: 'v=0\r\noffer-fake')),
          200,
        );
      }
      if (path.endsWith('/answer')) {
        return http.Response(
          jsonEncode(
            _sessionJson(
              state: 'accepted',
              offer: 'v=0\r\noffer-fake',
              answer: 'v=0\r\nanswer-fake',
            ),
          ),
          200,
        );
      }
      if (path.endsWith('/ice') && request.method == 'GET') {
        iceListCalls++;
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'seq': 1,
                'candidate': 'candidate:early-1',
                'client_ice_id': 'peer-early-1',
                'sdp_mid': '0',
                'sdp_mline_index': 0,
              },
            ],
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final hints = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(hints.close);
    final controller = _bob(media: media, client: client, hints: hints.stream);
    addTearDown(controller.dispose);
    await controller.startListening();

    hints.add({'type': 'call.ringing', 'call_id': 'call-1'});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(controller.phase, CallPhase.incomingRinging);

    hints.add({'type': 'call.ice', 'call_id': 'call-1'});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(media.remoteIce, isEmpty, reason: 'must not apply ICE before prepare');

    await controller.acceptIncoming();
    expect(media.remoteOffer, 'v=0\r\noffer-fake');
    expect(media.remoteIce, contains('candidate:early-1'));
    expect(iceListCalls, greaterThan(0));
  });
}

class _DelayedPrepareFake extends FakeCallService {
  _DelayedPrepareFake(this._gate);

  final Completer<void> _gate;

  @override
  Future<void> prepareIncoming({
    required CallMediaType mediaType,
    required bool enableVideo,
  }) async {
    await _gate.future;
    await super.prepareIncoming(mediaType: mediaType, enableVideo: enableVideo);
  }
}

