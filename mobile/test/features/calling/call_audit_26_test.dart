import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_messenger/core/network/api_client.dart';
import 'package:private_messenger/features/calling/call_auth.dart';
import 'package:private_messenger/features/calling/call_controller.dart';
import 'package:private_messenger/features/calling/calling_api_client.dart';
import 'package:private_messenger/features/calling/fake_call_service.dart';
import 'package:private_messenger/features/calling/models/call_session.dart';

/// Focused 19.7.26 audit coverage for lifecycle edges that D6 matrix names
/// but that were only partially asserted in older controller tests.
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
  required String myUserId,
  Stream<Map<String, dynamic>>? hints,
  Future<bool> Function(CallMediaType)? permissions,
}) {
  return CallController(
    api: CallingApiClient(client: client, baseUri: Uri.parse('http://example.test')),
    media: media,
    myUserId: myUserId,
    tokenProvider: () => 'tok',
    hintEvents: hints,
    requestPermissions: permissions ?? (_) async => true,
    authenticatePeer: (_) async =>
        const CallAuthOutcome(phase: CallAuthPhase.authenticated),
  );
}

void main() {
  test('outgoing audio call reaches ringing and posts an offer', () async {
    var offered = false;
    final media = FakeCallService();
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/calls') {
        return http.Response(jsonEncode(_sessionJson()), 201);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/offer')) {
        offered = true;
        return http.Response(
          jsonEncode(_sessionJson(offer: 'v=0\r\noffer-fake')),
          200,
        );
      }
      if (request.url.path.endsWith('/ice')) {
        return http.Response(jsonEncode({'candidates': []}), 200);
      }
      return http.Response('nope', 404);
    });
    final controller = _controller(media: media, client: client, myUserId: 'alice');
    addTearDown(controller.dispose);
    await controller.startOutgoing(
      peerUserId: 'bob',
      mediaType: CallMediaType.audio,
    );
    expect(controller.phase, CallPhase.outgoingRinging);
    expect(offered, isTrue);
    expect(media.prepared, isTrue);
  });

  test('incoming audio accept applies offer and posts answer', () async {
    var accepted = false;
    var answered = false;
    final media = FakeCallService();
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/accept')) {
        accepted = true;
        return http.Response(
          jsonEncode(_sessionJson(state: 'accepted', offer: 'v=0\r\noffer-fake')),
          200,
        );
      }
      if (request.method == 'GET' && request.url.path.endsWith('/calls/call-1')) {
        return http.Response(
          jsonEncode(_sessionJson(state: 'accepted', offer: 'v=0\r\noffer-fake')),
          200,
        );
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/answer')) {
        answered = true;
        return http.Response(
          jsonEncode(_sessionJson(
            state: 'accepted',
            offer: 'v=0\r\noffer-fake',
            answer: 'v=0\r\nanswer-fake',
          )),
          200,
        );
      }
      if (request.url.path.endsWith('/ice')) {
        return http.Response(jsonEncode({'candidates': []}), 200);
      }
      return http.Response('nope', 404);
    });
    final controller = _controller(media: media, client: client, myUserId: 'bob');
    addTearDown(controller.dispose);
    controller.phase = CallPhase.incomingRinging;
    controller.session = CallSession.fromJson(
      _sessionJson(state: 'ringing', offer: 'v=0\r\noffer-fake'),
    );
    await controller.acceptIncoming();
    expect(accepted, isTrue);
    expect(answered, isTrue);
    expect(media.remoteOffer, 'v=0\r\noffer-fake');
    expect(controller.phase, CallPhase.connecting);
  });

  test('outgoing and incoming video calls prepare video media', () async {
    for (final role in ['alice', 'bob']) {
      final media = FakeCallService();
      final client = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/calls') {
          return http.Response(jsonEncode(_sessionJson(media: 'video')), 201);
        }
        if (request.method == 'PUT' && request.url.path.endsWith('/offer')) {
          return http.Response(
            jsonEncode(_sessionJson(media: 'video', offer: 'v=0\r\noffer-fake')),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path.endsWith('/accept')) {
          return http.Response(
            jsonEncode(_sessionJson(
              media: 'video',
              state: 'accepted',
              offer: 'v=0\r\noffer-fake',
            )),
            200,
          );
        }
        if (request.method == 'GET' && request.url.path.endsWith('/calls/call-1')) {
          return http.Response(
            jsonEncode(_sessionJson(
              media: 'video',
              state: 'accepted',
              offer: 'v=0\r\noffer-fake',
            )),
            200,
          );
        }
        if (request.method == 'PUT' && request.url.path.endsWith('/answer')) {
          return http.Response(
            jsonEncode(_sessionJson(
              media: 'video',
              state: 'accepted',
              offer: 'v=0\r\noffer-fake',
              answer: 'v=0\r\nanswer-fake',
            )),
            200,
          );
        }
        if (request.url.path.endsWith('/ice')) {
          return http.Response(jsonEncode({'candidates': []}), 200);
        }
        return http.Response('nope', 404);
      });
      final controller = _controller(media: media, client: client, myUserId: role);
      addTearDown(controller.dispose);
      if (role == 'alice') {
        await controller.startOutgoing(
          peerUserId: 'bob',
          mediaType: CallMediaType.video,
        );
        expect(controller.phase, CallPhase.outgoingRinging);
      } else {
        controller.phase = CallPhase.incomingRinging;
        controller.session = CallSession.fromJson(
          _sessionJson(media: 'video', offer: 'v=0\r\noffer-fake'),
        );
        await controller.acceptIncoming();
        expect(controller.phase, CallPhase.connecting);
      }
      expect(media.prepared, isTrue);
      expect(media.prepareCount, 1);
    }
  });

  test('decline incoming cleans local media without accepting', () async {
    var declined = false;
    var accepted = false;
    final media = FakeCallService()..prepared = true;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/decline')) {
        declined = true;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      if (request.url.path.endsWith('/accept')) {
        accepted = true;
        return http.Response('should-not', 500);
      }
      return http.Response('nope', 404);
    });
    final controller = _controller(media: media, client: client, myUserId: 'bob');
    addTearDown(controller.dispose);
    controller.phase = CallPhase.incomingRinging;
    controller.session = CallSession.fromJson(_sessionJson());
    await controller.declineIncoming();
    expect(declined, isTrue);
    expect(accepted, isFalse);
    expect(media.disposed, isTrue);
    expect(controller.phase, anyOf(CallPhase.ended, CallPhase.idle));
  });

  test('cancel outgoing cleans local media', () async {
    var cancelled = false;
    final media = FakeCallService()..prepared = true;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/cancel')) {
        cancelled = true;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      return http.Response('nope', 404);
    });
    final controller = _controller(media: media, client: client, myUserId: 'alice');
    addTearDown(controller.dispose);
    controller.phase = CallPhase.outgoingRinging;
    controller.session = CallSession.fromJson(_sessionJson());
    await controller.cancelOutgoing();
    expect(cancelled, isTrue);
    expect(media.disposed, isTrue);
    expect(controller.phase, anyOf(CallPhase.ended, CallPhase.idle));
  });

  test('ICE negotiation failure hangs up and disposes media', () async {
    var hungUp = false;
    final media = FakeCallService();
    final hints = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(hints.close);
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/calls') {
        return http.Response(jsonEncode(_sessionJson()), 201);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/offer')) {
        return http.Response(
          jsonEncode(_sessionJson(offer: 'v=0\r\noffer-fake')),
          200,
        );
      }
      if (request.url.path == '/calls/active' ||
          request.url.path.endsWith('/calls/call-1')) {
        return http.Response(
          jsonEncode({
            if (request.url.path == '/calls/active')
              'call': _sessionJson(
                state: 'accepted',
                offer: 'v=0\r\noffer-fake',
                answer: 'v=0\r\nanswer-fake',
              )
            else
              ..._sessionJson(
                state: 'accepted',
                offer: 'v=0\r\noffer-fake',
                answer: 'v=0\r\nanswer-fake',
              ),
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/hangup')) {
        hungUp = true;
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      if (request.url.path.endsWith('/ice')) {
        return http.Response(jsonEncode({'candidates': []}), 200);
      }
      return http.Response('nope', 404);
    });
    final controller = _controller(
      media: media,
      client: client,
      myUserId: 'alice',
      hints: hints.stream,
    );
    addTearDown(controller.dispose);
    await controller.startOutgoing(
      peerUserId: 'bob',
      mediaType: CallMediaType.audio,
    );
    await controller.startListening();
    hints.add({'type': 'call.answer', 'call_id': 'call-1'});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    media.emitFailed();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(hungUp, isTrue);
    expect(media.disposed, isTrue);
  });

  test('TURN unavailable during ice-config fails closed', () async {
    final api = CallingApiClient(
      client: MockClient((_) async => http.Response('TURN unavailable', 503)),
      baseUri: Uri.parse('http://example.test'),
    );
    await expectLater(
      api.iceConfig(token: 'tok'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'message',
          contains('TURN unavailable'),
        ),
      ),
    );
  });

  test('delayed and duplicate call.offer hints refresh session without double-apply',
      () async {
    final media = FakeCallService();
    final hints = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(hints.close);
    var gets = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/calls/active') {
        return http.Response(jsonEncode({'call': null}), 200);
      }
      if (request.url.path.endsWith('/calls/call-1')) {
        gets++;
        return http.Response(
          jsonEncode(_sessionJson(state: 'ringing', offer: 'v=0\r\noffer-late')),
          200,
        );
      }
      if (request.method == 'POST' && request.url.path.endsWith('/accept')) {
        return http.Response(
          jsonEncode(_sessionJson(
            state: 'accepted',
            offer: 'v=0\r\noffer-late',
          )),
          200,
        );
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/answer')) {
        return http.Response(
          jsonEncode(_sessionJson(
            state: 'accepted',
            offer: 'v=0\r\noffer-late',
            answer: 'v=0\r\nanswer-fake',
          )),
          200,
        );
      }
      if (request.url.path.endsWith('/ice')) {
        return http.Response(jsonEncode({'candidates': []}), 200);
      }
      return http.Response('nope', 404);
    });
    final controller = _controller(
      media: media,
      client: client,
      myUserId: 'bob',
      hints: hints.stream,
    );
    addTearDown(controller.dispose);
    await controller.startListening();
    // First hint promotes idle → incomingRinging and stores offer on session.
    hints.add({'type': 'call.offer', 'call_id': 'call-1'});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(controller.phase, CallPhase.incomingRinging);
    expect(controller.session?.sdpOffer, 'v=0\r\noffer-late');
    expect(media.remoteOffer, isNull, reason: 'offer applied only on accept');

    // Duplicate delayed hint must not prepare media early.
    hints.add({'type': 'call.offer', 'call_id': 'call-1'});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(gets, greaterThanOrEqualTo(2));
    expect(media.remoteOffer, isNull);

    await controller.acceptIncoming();
    expect(media.remoteOffer, 'v=0\r\noffer-late');
  });

  test('video permission denial fails without preparing media', () async {
    final media = FakeCallService();
    final client = MockClient((request) async {
      fail('no network call when permissions are denied');
    });
    final controller = _controller(
      media: media,
      client: client,
      myUserId: 'alice',
      permissions: (_) async => false,
    );
    addTearDown(controller.dispose);
    await controller.startOutgoing(
      peerUserId: 'bob',
      mediaType: CallMediaType.video,
    );
    expect(controller.phase, CallPhase.failed);
    expect(controller.error, contains('permission'));
    expect(media.prepared, isFalse);
    expect(media.disposeCount, 0);
  });

  test('call cleanup leaves a subsequent messaging-style HTTP call usable', () async {
    var messagingGets = 0;
    final media = FakeCallService();
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/calls') {
        return http.Response(jsonEncode(_sessionJson()), 201);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/offer')) {
        return http.Response(
          jsonEncode(_sessionJson(offer: 'v=0\r\noffer-fake')),
          200,
        );
      }
      if (request.method == 'POST' && request.url.path.endsWith('/hangup')) {
        return http.Response(jsonEncode(_sessionJson(state: 'ended')), 200);
      }
      if (request.url.path.endsWith('/ice')) {
        return http.Response(jsonEncode({'candidates': []}), 200);
      }
      if (request.url.path == '/messaging/pending') {
        messagingGets++;
        return http.Response(jsonEncode({'envelopes': []}), 200);
      }
      return http.Response('nope', 404);
    });
    final controller = _controller(media: media, client: client, myUserId: 'alice');
    addTearDown(controller.dispose);
    await controller.startOutgoing(
      peerUserId: 'bob',
      mediaType: CallMediaType.audio,
    );
    await controller.hangUp();
    expect(media.disposed, isTrue);

    // Shared HTTP client remains usable for messaging after call teardown.
    final msg = await client.get(
      Uri.parse('http://example.test/messaging/pending'),
      headers: {'authorization': 'Bearer tok'},
    );
    expect(msg.statusCode, 200);
    expect(messagingGets, 1);
    expect(controller.phase, anyOf(CallPhase.ended, CallPhase.idle));
  });
}
