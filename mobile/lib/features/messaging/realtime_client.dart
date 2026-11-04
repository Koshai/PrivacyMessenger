import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Authenticated WebSocket client with reconnect + backoff.
///
/// Auth uses a post-connect handshake frame (never query-string tokens).
/// Events are hints only — durable sync uses HTTP pending endpoints.
class RealtimeClient {
  RealtimeClient({required this.wsBaseUri});

  final Uri wsBaseUri;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnect;
  int _attempt = 0;
  bool _stopped = true;
  String? _token;

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  final _revoked = StreamController<void>.broadcast();
  Stream<void> get sessionRevoked => _revoked.stream;

  Future<void> start(String token) async {
    _stopped = false;
    _token = token;
    await _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    _token = null;
    _reconnect?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> _connect() async {
    if (_stopped || _token == null) return;
    try {
      // No access_token in the URL (C3).
      final uri = wsBaseUri.replace(queryParameters: {});
      _channel = WebSocketChannel.connect(uri);
      _channel!.sink.add(jsonEncode({
        'type': 'auth',
        'token': _token,
      }));

      _sub = _channel!.stream.listen(
        (raw) {
          if (raw is! String) return;
          final decoded = jsonDecode(raw);
          if (decoded is! Map<String, dynamic>) return;
          if (decoded['type'] == 'session_revoked') {
            _revoked.add(null);
            stop();
            return;
          }
          _events.add(decoded);
          _attempt = 0;
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
      );
      _attempt = 0;
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_stopped || _token == null) return;
    _reconnect?.cancel();
    final delay =
        Duration(milliseconds: (500 * (1 << _attempt.clamp(0, 5))).toInt());
    _attempt++;
    _reconnect = Timer(delay, () {
      _connect();
    });
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _revoked.close();
  }
}
