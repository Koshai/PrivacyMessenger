import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Authenticated WebSocket client with reconnect + backoff.
///
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

  Future<void> start(String token) async {
    _stopped = false;
    _token = token;
    await _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    _reconnect?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> _connect() async {
    if (_stopped || _token == null) return;
    try {
      final uri = wsBaseUri.replace(
        queryParameters: {'access_token': _token},
      );
      // Prefer Authorization via headers when available; fallback query for tools.
      _channel = WebSocketChannel.connect(
        uri,
        protocols: const [],
      );
      // Send token as first message if server expects header-only auth via HTTP
      // upgrade — our server uses Authorization on the handshake; browsers need
      // a custom approach. For mobile http client we pass via Sec header by
      // using a custom connect — coder path uses Bearer on HTTP upgrade.
      _sub = _channel!.stream.listen(
        (raw) {
          if (raw is! String) return;
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            _events.add(decoded);
            _attempt = 0;
          }
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
    if (_stopped) return;
    _reconnect?.cancel();
    final delay = Duration(milliseconds: (500 * (1 << _attempt.clamp(0, 5))).toInt());
    _attempt++;
    _reconnect = Timer(delay, () {
      _connect();
    });
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}
