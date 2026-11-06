import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'delivery_timing.dart';

/// Minimal socket surface used by [RealtimeClient] (production uses
/// [WebSocketChannel.connect]).
abstract class RealtimeSocket {
  Stream get stream;
  void add(String data);
  Future<void> close();
  int? get closeCode;
}

class _ChannelSocket implements RealtimeSocket {
  _ChannelSocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream get stream => _channel.stream;

  @override
  void add(String data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close();

  @override
  int? get closeCode {
    try {
      return _channel.closeCode;
    } catch (_) {
      return null;
    }
  }
}

typedef RealtimeConnect = RealtimeSocket Function(Uri uri);

/// Authenticated WebSocket client with reconnect + backoff.
///
/// Auth uses a post-connect handshake frame (never query-string tokens).
/// Events are hints only — durable sync uses HTTP pending endpoints.
class RealtimeClient {
  RealtimeClient({
    required this.wsBaseUri,
    RealtimeConnect? connect,
  }) : _connectFn = connect ??
            ((uri) => _ChannelSocket(WebSocketChannel.connect(uri)));

  final Uri wsBaseUri;
  final RealtimeConnect _connectFn;

  RealtimeSocket? _channel;
  StreamSubscription? _sub;
  Timer? _reconnect;
  int _attempt = 0;
  bool _stopped = true;
  bool _connecting = false;
  String? _token;
  Stopwatch? _lifetime;

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;
  int _eventsWithoutListener = 0;
  int get eventsWithoutListener => _eventsWithoutListener;

  final _revoked = StreamController<void>.broadcast();
  Stream<void> get sessionRevoked => _revoked.stream;

  bool get isStarted => !_stopped;
  int get reconnectAttempt => _attempt;

  Future<void> start(String token) async {
    _stopped = false;
    _token = token;
    await _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    _token = null;
    _reconnect?.cancel();
    _reconnect = null;
    await _tearDownSocket(category: 'client_stop');
  }

  Future<void> _connect() async {
    if (_stopped || _token == null || _connecting) return;
    _connecting = true;
    DeliveryTiming.record('realtime_connect_attempt', _attempt);
    try {
      await _tearDownSocket(category: 'reconnect_replace');

      // No access_token in the URL (C3).
      final uri = wsBaseUri.replace(queryParameters: {});
      final channel = _connectFn(uri);
      _channel = channel;
      _lifetime = Stopwatch()..start();
      channel.add(jsonEncode({
        'type': 'auth',
        'token': _token,
      }));

      _sub = channel.stream.listen(
        (raw) {
          if (raw is! String) return;
          final decoded = jsonDecode(raw);
          if (decoded is! Map<String, dynamic>) return;
          if (decoded['type'] == 'session_revoked') {
            _emitClose(
              category: 'session_revoked',
              code: channel.closeCode,
            );
            _revoked.add(null);
            stop();
            return;
          }
          if (decoded['type'] == 'connected') {
            _attempt = 0;
            DeliveryTiming.record(
              'realtime_connected',
              _lifetime?.elapsedMilliseconds ?? 0,
            );
          }
          _emit(decoded);
        },
        onDone: () {
          _emitClose(
            category: 'socket_done',
            code: channel.closeCode,
          );
          _scheduleReconnect();
        },
        onError: (Object error) {
          _emitClose(
            category: 'socket_error',
            code: channel.closeCode,
            detail: error.runtimeType.toString(),
          );
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
    } catch (error) {
      _emitClose(
        category: 'connect_failed',
        detail: error.runtimeType.toString(),
      );
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _scheduleReconnect() {
    if (_stopped || _token == null) return;
    _reconnect?.cancel();
    final delay =
        Duration(milliseconds: (500 * (1 << _attempt.clamp(0, 5))).toInt());
    DeliveryTiming.record('realtime_reconnect_wait', delay.inMilliseconds);
    _emit({
      'type': 'client_reconnecting',
      'attempt': _attempt,
      'delay_ms': delay.inMilliseconds,
    });
    _attempt++;
    _reconnect = Timer(delay, () {
      _connect();
    });
  }

  Future<void> _tearDownSocket({required String category}) async {
    final sub = _sub;
    final channel = _channel;
    _sub = null;
    _channel = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    if (channel != null) {
      try {
        await channel.close();
      } catch (_) {}
    }
    final life = _lifetime;
    if (life != null && life.isRunning) {
      DeliveryTiming.record(
        'realtime_socket_closed',
        life.elapsedMilliseconds,
        detail: category,
      );
      life.stop();
    }
    _lifetime = null;
  }

  void _emitClose({
    required String category,
    int? code,
    String? detail,
  }) {
    DeliveryTiming.record(
      'realtime_close',
      _lifetime?.elapsedMilliseconds ?? 0,
      detail: category,
    );
    if (code != null) {
      DeliveryTiming.record('realtime_close_code', code);
    }
    if (detail != null) {
      DeliveryTiming.record(
        'realtime_close_detail',
        0,
        detail: detail,
      );
    }
  }

  void _emit(Map<String, dynamic> event) {
    final type = event['type'];
    final detail = type is String ? type : 'unknown';
    if (!_events.hasListener) {
      _eventsWithoutListener++;
      DeliveryTiming.record(
        'realtime_event_without_listener',
        _eventsWithoutListener,
        detail: detail,
      );
    }
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _revoked.close();
  }
}
