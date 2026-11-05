import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/call_service.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';

Map<String, dynamic> _sessionJson({
  String id = 'call-1',
  String state = 'ringing',
  String media = 'audio',
  String? offer,
  String? answer,
  String caller = 'alice',
  String callee = 'bob',
}) {
  return {
    'id': id,
    'caller_user_id': caller,
    'callee_user_id': callee,
    'caller_device_id': 'adev',
    'media_type': media,
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

CallController _controller({
  required FakeCallService media,
  required MockClient client,
  String myUserId = 'alice',
  Stream<Map<String, dynamic>>? hints,
  Future<bool> Function(CallMediaType)? permissions,
  CallAuthenticator? authenticatePeer,
  bool injectAuthenticator = true,
}) {
  return CallController(
    api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
    media: media,
    myUserId: myUserId,
    tokenProvider: () => 'tok',
    hintEvents: hints,
    requestPermissions: permissions ?? (_) async => true,
    authenticatePeer: injectAuthenticator
        ? (authenticatePeer ??
            (_) async => const CallAuthOutcome(phase: CallAuthPhase.authenticated))
        : null,
  );
}

void main() {
  test('outgoing flow mute and hangup cleans media', () async {
    final media = FakeCallService();
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/calls') {
        return http.Response(jsonEncode(_sessionJson()), 201);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/offer')) {
        return http.Response(
          jsonEncode(_sessionJson(state: 'ringing', offer: 'v=0\r\noffer-fake')),
          200,
        );
      }
      if (request.method == 'POST' && request.url.path.endsWith('/hangup')) {
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      if (request.url.path.endsWith('/ice')) {
        return http.Response(jsonEncode({'candidates': []}), 200);
      }
      return http.Response('nope', 404);
    });

    final controller = _controller(media: media, client: client);
    await controller.startOutgoing(peerUserId: 'bob', mediaType: CallMediaType.audio);
    expect(controller.phase, CallPhase.outgoingRinging);

    await controller.toggleMute();
    expect(media.micMuted, isTrue);

    await controller.hangUp();
    expect(media.disposed, isTrue);
    expect(controller.phase, anyOf(CallPhase.ended, CallPhase.idle));
  });

  test('permission denial fails without preparing media', () async {
    final media = FakeCallService();
    final controller = _controller(
      media: media,
      client: MockClient((_) async => http.Response('no', 500)),
      permissions: (_) async => false,
    );

    await controller.startOutgoing(peerUserId: 'bob', mediaType: CallMediaType.video);
    expect(controller.phase, CallPhase.failed);
    expect(controller.error, contains('permission'));
    expect(media.prepareCount, 0);
  });

  test('logout hangs up active call', () async {
    final media = FakeCallService();
    var hungUp = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/hangup')) {
        hungUp = true;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      return http.Response(jsonEncode(_sessionJson(state: 'connected')), 200);
    });
    final controller = _controller(media: media, client: client);
    controller.phase = CallPhase.connected;
    controller.session = CallSession.fromJson(_sessionJson(state: 'connected'));
    await controller.onLogout();
    expect(hungUp, isTrue);
    expect(media.disposed, isTrue);
  });

  test('duplicate remote answer is applied once', () async {
    final media = FakeCallService();
    final hints = StreamController<Map<String, dynamic>>.broadcast();
    final answer = 'v=0\r\nanswer-dup';
    final client = MockClient((request) async {
      if (request.url.path == '/calls/call-1') {
        return http.Response(
          jsonEncode(_sessionJson(state: 'accepted', answer: answer)),
          200,
        );
      }
      if (request.url.path.endsWith('/ice')) {
        return http.Response(jsonEncode({'candidates': []}), 200);
      }
      return http.Response(jsonEncode(_sessionJson(state: 'accepted', answer: answer)), 200);
    });
    final controller = _controller(media: media, client: client, hints: hints.stream);
    controller.phase = CallPhase.outgoingRinging;
    controller.session = CallSession.fromJson(_sessionJson(state: 'ringing'));
    await controller.startListening();

    hints.add({'type': 'call.answer', 'call_id': 'call-1'});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    hints.add({'type': 'call.answer', 'call_id': 'call-1'});
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(media.applyAnswerCount, 1);
    expect(media.remoteAnswer, answer);
    await hints.close();
  });

  test('late ICE candidates are forwarded to media', () async {
    final media = FakeCallService();
    final client = MockClient((request) async {
      if (request.url.path == '/calls/active') {
        return http.Response(
          jsonEncode({'call': _sessionJson(state: 'accepted')}),
          200,
        );
      }
      if (request.url.path.endsWith('/ice') && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'seq': 3,
                'candidate': 'candidate:1 1 UDP 2122 1.2.3.4 1234 typ host',
                'client_ice_id': 'peer-3',
                'sdp_mid': '0',
                'sdp_mline_index': 0,
              }
            ],
          }),
          200,
        );
      }
      return http.Response(jsonEncode(_sessionJson(state: 'accepted')), 200);
    });
    final controller = _controller(media: media, client: client);
    await controller.startListening();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(media.remoteIce, isNotEmpty);
  });

  test('camera and speaker controls update media adapter', () async {
    final media = FakeCallService();
    final controller = _controller(
      media: media,
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    controller.phase = CallPhase.connected;
    controller.session = CallSession.fromJson(
      _sessionJson(state: 'connected', media: 'video'),
    );

    await controller.toggleSpeaker();
    expect(media.speakerOn, isTrue);
    await controller.toggleCamera();
    expect(media.cameraOn, isFalse);
    await controller.switchCamera();
    expect(media.switches, 1);
  });

  test('network hangup failure still disposes local media', () async {
    final media = FakeCallService();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/hangup')) {
        throw Exception('network down');
      }
      return http.Response('{}', 500);
    });
    final controller = _controller(media: media, client: client);
    controller.phase = CallPhase.connected;
    controller.session = CallSession.fromJson(_sessionJson(state: 'connected'));
    await controller.hangUp();
    expect(media.disposed, isTrue);
  });

  test('reconcile clears local call when server has none', () async {
    final media = FakeCallService();
    final client = MockClient((request) async {
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': null}), 200);
      }
      return http.Response('{}', 404);
    });
    final controller = _controller(media: media, client: client);
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_sessionJson(state: 'accepted'));
    await media.prepareOutgoing(mediaType: CallMediaType.audio, enableVideo: false);
    await controller.reconcileActive();
    expect(media.disposed, isTrue);
    expect(controller.phase, anyOf(CallPhase.ended, CallPhase.idle));
  });

  test('client-reported connected marks phase connected', () async {
    final media = FakeCallService();
    var marked = false;
    final client = MockClient((request) async {
      if (request.url.path == '/calls/active') {
        return http.Response(
          jsonEncode({'call': _sessionJson(state: 'accepted')}),
          200,
        );
      }
      if (request.url.path.endsWith('/connected')) {
        marked = true;
        return http.Response(jsonEncode(_sessionJson(state: 'connected')), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = _controller(media: media, client: client);
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_sessionJson(state: 'accepted'));
    await controller.startListening();
    media.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.phase, CallPhase.connected);
    expect(marked, isTrue);
    expect(controller.localMediaConnected, isTrue);
  });

  test('connection failed hangs up and cleans media', () async {
    final media = FakeCallService();
    var hungUp = false;
    final client = MockClient((request) async {
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': _sessionJson(state: 'accepted')}), 200);
      }
      if (request.url.path.endsWith('/hangup')) {
        hungUp = true;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = _controller(media: media, client: client);
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_sessionJson(state: 'accepted'));
    await controller.startListening();
    media.emitFailed();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(hungUp, isTrue);
    expect(media.disposed, isTrue);
  });

  test('retries failed local ICE then succeeds', () async {
    final media = FakeCallService();
    var attempts = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/ice') && request.method == 'POST') {
        attempts++;
        if (attempts < 3) return http.Response('temp', 500);
        return http.Response('{}', 201);
      }
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': _sessionJson(state: 'accepted')}), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = _controller(media: media, client: client);
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_sessionJson(state: 'accepted'));
    await controller.startListening();
    media.emitLocalIce('candidate:local');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(attempts, 3);
    expect(controller.phase, isNot(CallPhase.failed));
  });

  test('remote ICE cursor stays put when apply fails', () async {
    final media = FakeCallService()..failCandidateContaining = 'bad';
    var polls = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': _sessionJson(state: 'accepted')}), 200);
      }
      if (request.method == 'GET' && request.url.path.endsWith('/ice')) {
        polls++;
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'seq': 1,
                'candidate': 'bad-candidate',
                'client_ice_id': 'c1',
              }
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    final controller = _controller(media: media, client: client);
    await controller.startListening();
    await Future<void>.delayed(const Duration(milliseconds: 2300));
    expect(polls, greaterThan(1));
    expect(media.remoteIce, isEmpty);
  });

  test('server connected does not mark local media connected', () async {
    final media = FakeCallService();
    final client = MockClient((request) async {
      if (request.url.path == '/calls/active') {
        return http.Response(
          jsonEncode({'call': _sessionJson(state: 'connected')}),
          200,
        );
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = _controller(media: media, client: client);
    await controller.startListening();
    expect(controller.phase, CallPhase.connecting);
    expect(controller.localMediaConnected, isFalse);
  });

  test('setup failure after initiate hangs up the server call', () async {
    final media = FakeCallService();
    var hungUp = false;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/calls') {
        return http.Response(jsonEncode(_sessionJson()), 201);
      }
      if (request.url.path.endsWith('/offer')) {
        return http.Response('boom', 500);
      }
      if (request.url.path.endsWith('/hangup')) {
        hungUp = true;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = _controller(media: media, client: client);
    await controller.startOutgoing(peerUserId: 'bob', mediaType: CallMediaType.audio);
    expect(hungUp, isTrue);
    expect(controller.phase, anyOf(CallPhase.failed, CallPhase.ended, CallPhase.idle));
  });

  test('stale refresh does not overwrite a newer call', () async {
    final media = FakeCallService();
    final gate = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.path == '/calls/old') {
        await gate.future;
        return http.Response(jsonEncode(_sessionJson(id: 'old', state: 'connected')), 200);
      }
      if (request.method == 'POST' && request.url.path == '/calls') {
        return http.Response(jsonEncode(_sessionJson(id: 'new')), 201);
      }
      if (request.url.path.endsWith('/offer')) {
        return http.Response(jsonEncode(_sessionJson(id: 'new', offer: 'v=0\r\noffer-fake')), 200);
      }
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': null}), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final hints = StreamController<Map<String, dynamic>>.broadcast();
    final controller = _controller(media: media, client: client, hints: hints.stream);
    await controller.startListening();
    hints.add({'type': 'call.answer', 'call_id': 'old'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await controller.startOutgoing(peerUserId: 'bob', mediaType: CallMediaType.audio);
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.session?.id, 'new');
    expect(controller.phase, CallPhase.outgoingRinging);
    await hints.close();
  });

  test('hangup is idempotent and releases media once', () async {
    final media = FakeCallService();
    var hangups = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/hangup')) {
        hangups++;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      return http.Response('{}', 200);
    });
    final controller = _controller(media: media, client: client);
    controller.phase = CallPhase.connected;
    controller.session = CallSession.fromJson(_sessionJson(state: 'connected'));
    await controller.hangUp();
    await controller.hangUp();
    expect(hangups, 1);
    expect(media.disposeCount, 1);
  });

  test('navigation away and logout end the call', () async {
    final media = FakeCallService();
    var hangups = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/hangup')) {
        hangups++;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      return http.Response('{}', 200);
    });
    final controller = _controller(media: media, client: client);
    controller.phase = CallPhase.incomingRinging;
    controller.session = CallSession.fromJson(_sessionJson());
    await controller.onNavigationAway();
    expect(hangups, 1);

    controller.phase = CallPhase.connected;
    controller.session = CallSession.fromJson(_sessionJson(state: 'connected'));
    await controller.onLogout();
    expect(hangups, 2);
  });

  test('short disconnect recovers; long disconnect ends the call', () async {
    final media = FakeCallService();
    var hangups = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': _sessionJson(state: 'accepted')}), 200);
      }
      if (request.url.path.endsWith('/hangup')) {
        hangups++;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      if (request.url.path.endsWith('/connected')) {
        return http.Response(jsonEncode(_sessionJson(state: 'connected')), 200);
      }
      return http.Response(jsonEncode({'candidates': []}), 200);
    });
    final controller = CallController(
      api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
      media: media,
      myUserId: 'alice',
      tokenProvider: () => 'tok',
      requestPermissions: (_) async => true,
      disconnectGrace: const Duration(milliseconds: 80),
      authenticatePeer: (_) async =>
          const CallAuthOutcome(phase: CallAuthPhase.authenticated),
    );
    controller.phase = CallPhase.connecting;
    controller.session = CallSession.fromJson(_sessionJson(state: 'accepted'));
    await controller.startListening();
    media.emit(const CallMediaEvent(kind: CallMediaEventKind.connectionDisconnected));
    media.emitConnected();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(hangups, 0);
    expect(controller.phase, CallPhase.connected);

    media.emit(const CallMediaEvent(kind: CallMediaEventKind.connectionDisconnected));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(hangups, 1);
  });
}
