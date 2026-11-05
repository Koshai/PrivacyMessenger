import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/network/api_client.dart';
import 'ice_servers.dart';
import 'models/call_session.dart';

/// Thin HTTP client for Go calling endpoints (D1/D1.1).
class CallingApiClient {
  CallingApiClient({required this.client, required this.baseUri});

  final http.Client client;
  final Uri baseUri;

  Map<String, String> _headers(String token) => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  Future<CallSession> initiate({
    required String token,
    required String calleeUserId,
    required CallMediaType mediaType,
    required String clientCallId,
  }) async {
    final response = await _send(
      () => client.post(
        baseUri.resolve('/calls'),
        headers: _headers(token),
        body: jsonEncode({
          'callee_user_id': calleeUserId,
          'media_type': mediaType == CallMediaType.video ? 'video' : 'audio',
          'client_call_id': clientCallId,
        }),
      ),
    );
    _ensure(response, ok: {200, 201});
    return CallSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<CallSession> accept({required String token, required String callId}) =>
      _mutate(token, callId, 'accept');

  Future<CallSession> decline({required String token, required String callId}) =>
      _mutate(token, callId, 'decline');

  Future<CallSession> cancel({required String token, required String callId}) =>
      _mutate(token, callId, 'cancel');

  Future<CallSession> hangup({required String token, required String callId}) =>
      _mutate(token, callId, 'hangup');

  Future<CallSession> markConnected({
    required String token,
    required String callId,
  }) =>
      _mutate(token, callId, 'connected');

  Future<CallSession> setOffer({
    required String token,
    required String callId,
    required String sdp,
  }) =>
      _putSdp(token, callId, 'offer', sdp);

  Future<CallSession> setAnswer({
    required String token,
    required String callId,
    required String sdp,
  }) =>
      _putSdp(token, callId, 'answer', sdp);

  Future<void> addIce({
    required String token,
    required String callId,
    required String candidate,
    required String clientIceId,
    String? sdpMid,
    int? sdpMLineIndex,
  }) async {
    final response = await _send(
      () => client.post(
        baseUri.resolve('/calls/$callId/ice'),
        headers: _headers(token),
        body: jsonEncode({
          'candidate': candidate,
          'client_ice_id': clientIceId,
          'sdp_mid': ?sdpMid,
          'sdp_mline_index': ?sdpMLineIndex,
        }),
      ),
    );
    _ensure(response, ok: {200, 201});
  }

  Future<List<IceCandidateDto>> listIce({
    required String token,
    required String callId,
    int after = 0,
  }) async {
    final response = await _send(
      () => client.get(
        baseUri.resolve('/calls/$callId/ice?after=$after'),
        headers: _headers(token),
      ),
    );
    _ensure(response, ok: {200});
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final list = decoded['candidates'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(IceCandidateDto.fromJson)
        .toList();
  }

  Future<IceServerConfig> iceConfig({
    required String token,
    bool relayOnly = false,
  }) async {
    final response = await _send(
      () => client.get(
        baseUri.resolve('/calls/ice-config'),
        headers: _headers(token),
      ),
    );
    if (response.statusCode == 503) {
      throw const ApiException(
        'TURN unavailable',
        kind: ApiErrorKind.server,
        statusCode: 503,
      );
    }
    _ensure(response, ok: {200});
    return IceServerConfig.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
      relayOnly: relayOnly,
    );
  }

  Future<CallSession?> active({required String token}) async {
    final response = await _send(
      () => client.get(
        baseUri.resolve('/calls/active'),
        headers: _headers(token),
      ),
    );
    _ensure(response, ok: {200});
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final call = decoded['call'];
    if (call == null) return null;
    return CallSession.fromJson(call as Map<String, dynamic>);
  }

  Future<CallSession> get({required String token, required String callId}) async {
    final response = await _send(
      () => client.get(
        baseUri.resolve('/calls/$callId'),
        headers: _headers(token),
      ),
    );
    _ensure(response, ok: {200});
    return CallSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<CallSession> _mutate(String token, String callId, String action) async {
    final response = await _send(
      () => client.post(
        baseUri.resolve('/calls/$callId/$action'),
        headers: _headers(token),
      ),
    );
    _ensure(response, ok: {200});
    return CallSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<CallSession> _putSdp(
    String token,
    String callId,
    String kind,
    String sdp,
  ) async {
    final response = await _send(
      () => client.put(
        baseUri.resolve('/calls/$callId/$kind'),
        headers: _headers(token),
        body: jsonEncode({'sdp': sdp}),
      ),
    );
    _ensure(response, ok: {200});
    return CallSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<http.Response> _send(Future<http.Response> Function() run) async {
    try {
      return await run().timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const ApiException('Calling request timed out', kind: ApiErrorKind.timeout);
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException('Calling network error: $e', kind: ApiErrorKind.network);
    }
  }

  void _ensure(http.Response response, {required Set<int> ok}) {
    if (ok.contains(response.statusCode)) return;
    final kind = switch (response.statusCode) {
      401 => ApiErrorKind.unauthorized,
      404 => ApiErrorKind.validation,
      409 => ApiErrorKind.validation,
      413 => ApiErrorKind.validation,
      429 => ApiErrorKind.rateLimited,
      _ => ApiErrorKind.server,
    };
    throw ApiException(
      response.body.isEmpty ? 'Calling HTTP ${response.statusCode}' : response.body,
      kind: kind,
      statusCode: response.statusCode,
    );
  }
}
