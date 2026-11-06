import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/messaging/delivery_timing.dart';
import 'package:private_messenger/features/messaging/realtime_client.dart';

void main() {
  setUp(DeliveryTiming.reset);

  test('reconnect emits client_reconnecting and recovers', () async {
    final factory = _SocketFactory();
    final client = RealtimeClient(
      wsBaseUri: Uri.parse('ws://example.test/realtime/ws'),
      connect: factory.connect,
    );
    addTearDown(client.dispose);

    final events = <String>[];
    client.events.listen((event) {
      events.add('${event['type']}');
    });

    await client.start('session-token');
    await _until(() => factory.current != null);
    expect(jsonDecode(factory.current!.auth!)['type'], 'auth');
    factory.current!.push({'type': 'connected'});
    await _until(() => events.contains('connected'));

    factory.current!.completeDone();
    await _until(() => events.contains('client_reconnecting'));
    expect(
      DeliveryTiming.events.any((e) => e.stage == 'realtime_reconnect_wait'),
      isTrue,
    );

    await _until(() => factory.openCount >= 2);
    factory.current!.push({'type': 'connected'});
    factory.current!.push({'type': 'envelope'});
    await _until(() => events.where((e) => e == 'connected').length >= 2);
    expect(events.contains('envelope'), isTrue);
    expect(client.reconnectAttempt, 0);
  });

  test('events without a listener are counted and not retained', () async {
    final factory = _SocketFactory();
    final client = RealtimeClient(
      wsBaseUri: Uri.parse('ws://example.test/realtime/ws'),
      connect: factory.connect,
    );
    addTearDown(client.dispose);

    await client.start('session-token');
    await _until(() => factory.current != null);
    factory.current!.push({'type': 'connected'});
    factory.current!.push({'type': 'envelope'});
    await _until(() => client.eventsWithoutListener >= 1);

    final later = <String>[];
    client.events.listen((event) => later.add('${event['type']}'));
    await Future<void>.delayed(Duration.zero);
    expect(later, isEmpty);
  });
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition was not reached');
}

class _SocketFactory {
  _FakeSocket? current;
  int openCount = 0;

  RealtimeSocket connect(Uri uri) {
    openCount++;
    final socket = _FakeSocket();
    current = socket;
    return socket;
  }
}

class _FakeSocket implements RealtimeSocket {
  final _controller = StreamController<dynamic>.broadcast();
  String? auth;

  void push(Map<String, Object?> event) {
    if (!_controller.isClosed) {
      _controller.add(jsonEncode(event));
    }
  }

  void completeDone() {
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  @override
  Stream get stream => _controller.stream;

  @override
  void add(String data) => auth = data;

  @override
  Future<void> close() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  @override
  int? get closeCode => null;
}
