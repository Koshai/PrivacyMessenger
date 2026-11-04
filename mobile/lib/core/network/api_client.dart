import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;

import '../../features/auth/models/otp_challenge.dart';
import '../../features/auth/models/auth_session.dart';
import '../../features/auth/models/auth_identity.dart';
import '../../features/friends/models/friend.dart';
import '../../features/messaging/models/envelope.dart';

enum ApiErrorKind {
  unauthorized,
  validation,
  rateLimited,
  network,
  timeout,
  server,
  invalidResponse,
  unknown,
}

class ApiException implements Exception {
  final String message;
  final ApiErrorKind kind;
  final int? statusCode;

  const ApiException(
    this.message, {
    this.kind = ApiErrorKind.unknown,
    this.statusCode,
  });

  bool get isUnauthorized => kind == ApiErrorKind.unauthorized;

  @override
  String toString() => 'ApiException($kind): $message';
}

class ApiClient {
  final http.Client client;
  final Uri baseUri;

  ApiClient({required this.client, required this.baseUri});

  Future<bool> checkHealth() async {
    try {
      final uri = baseUri.resolve('/health');

      final response = await client
          .get(uri)
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        throw ApiException(
          'Health check failed: HTTP ${response.statusCode}',
          kind: ApiErrorKind.server,
          statusCode: response.statusCode,
        );
      }

      final body = jsonDecode(response.body);

      if (body is! Map<String, dynamic>) {
        throw const ApiException(
          'Invalid health response',
          kind: ApiErrorKind.invalidResponse,
        );
      }

      return body['status'] == 'ok';
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'Health check timed out',
        kind: ApiErrorKind.timeout,
      );
    } catch (error) {
      throw ApiException(
        'Unable to reach API: ${error.runtimeType}',
        kind: ApiErrorKind.network,
      );
    }
  }

  Future<OtpChallenge> requestOtp(String email) async {
    final normalizedEmail = email.trim();

    if (normalizedEmail.isEmpty) {
      throw const ApiException(
        'Email is required',
        kind: ApiErrorKind.validation,
      );
    }

    try {
      final response = await client
          .post(
            baseUri.resolve('/auth/request-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': normalizedEmail}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 400) {
        throw const ApiException(
          'Invalid email address',
          kind: ApiErrorKind.validation,
          statusCode: 400,
        );
      }

      if (response.statusCode == 429) {
        throw const ApiException(
          'Too many requests. Please try again later.',
          kind: ApiErrorKind.rateLimited,
          statusCode: 429,
        );
      }

      if (response.statusCode != 202) {
        throw ApiException(
          'Unable to request verification code',
          kind: ApiErrorKind.server,
          statusCode: response.statusCode,
        );
      }

      final decoded = jsonDecode(response.body);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid OTP response format');
      }

      return OtpChallenge.fromJson(decoded);
    } on ApiException {
      rethrow;
    } on FormatException {
      throw const ApiException(
        'Authentication server returned invalid data',
        kind: ApiErrorKind.invalidResponse,
      );
    } on TimeoutException {
      throw const ApiException(
        'Verification request timed out',
        kind: ApiErrorKind.timeout,
      );
    } catch (_) {
      throw const ApiException(
        'Unable to connect to the authentication server',
        kind: ApiErrorKind.network,
      );
    }
  }

  Future<AuthSession> verifyOtp({
    required String challengeId,
    required String code,
    required String deviceName,
  }) async {
    final normalizedCode = code.trim();
    final normalizedDeviceName = deviceName.trim();

    if (challengeId.trim().isEmpty ||
        !RegExp(r'^[0-9]{6}$').hasMatch(normalizedCode) ||
        normalizedDeviceName.isEmpty ||
        normalizedDeviceName.length > 100) {
      throw const ApiException(
        'Invalid verification request',
        kind: ApiErrorKind.validation,
      );
    }

    try {
      final response = await client
          .post(
            baseUri.resolve('/auth/verify-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'challenge_id': challengeId.trim(),
              'code': normalizedCode,
              'device_name': normalizedDeviceName,
            }),
          )
          .timeout(const Duration(seconds: 10));

      switch (response.statusCode) {
        case 200:
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is! Map<String, dynamic>) {
              throw const FormatException('Invalid JSON structure');
            }
            return AuthSession.fromJson(decoded);
          } on FormatException {
            throw const ApiException(
              'Authentication server returned invalid data',
              kind: ApiErrorKind.invalidResponse,
              statusCode: 200,
            );
          }

        case 400:
          throw const ApiException(
            'Invalid verification request',
            kind: ApiErrorKind.validation,
            statusCode: 400,
          );

        case 401:
          throw const ApiException(
            'Invalid or expired verification code',
            kind: ApiErrorKind.unauthorized,
            statusCode: 401,
          );

        case 429:
          throw const ApiException(
            'Too many attempts. Please try again later.',
            kind: ApiErrorKind.rateLimited,
            statusCode: 429,
          );

        default:
          throw ApiException(
            'Unable to verify your code. Please try again.',
            kind: ApiErrorKind.server,
            statusCode: response.statusCode,
          );
      }
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'Verification request timed out',
        kind: ApiErrorKind.timeout,
      );
    } catch (_) {
      throw const ApiException(
        'Unable to connect to authentication server',
        kind: ApiErrorKind.network,
      );
    }
  }

  Future<AuthIdentity> getAuthenticatedUser(String token) async {
    if (token.trim().isEmpty) {
      throw const ApiException(
        'Authentication required',
        kind: ApiErrorKind.unauthorized,
      );
    }

    try {
      final response = await client
          .get(
            baseUri.resolve('/auth/me'),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));

      switch (response.statusCode) {
        case 200:
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is! Map<String, dynamic>) {
              throw const FormatException('Invalid response structure');
            }
            return AuthIdentity.fromJson(decoded);
          } on FormatException {
            throw const ApiException(
              'Authentication server returned invalid data',
              kind: ApiErrorKind.invalidResponse,
              statusCode: 200,
            );
          }

        case 401:
          throw const ApiException(
            'Session expired or revoked',
            kind: ApiErrorKind.unauthorized,
            statusCode: 401,
          );

        default:
          throw ApiException(
            'Unable to validate session',
            kind: ApiErrorKind.server,
            statusCode: response.statusCode,
          );
      }
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'Session validation timed out',
        kind: ApiErrorKind.timeout,
      );
    } catch (_) {
      throw const ApiException(
        'Unable to connect to authentication server',
        kind: ApiErrorKind.network,
      );
    }
  }

  Future<void> logout(String token) async {
    http.Response response;

    try {
      response = await client
          .post(
            baseUri.resolve('/auth/logout'),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw const ApiException(
        'Unable to contact the server. Please try logging out again.',
        kind: ApiErrorKind.timeout,
      );
    } catch (_) {
      throw const ApiException(
        'Unable to contact the server. Please try logging out again.',
        kind: ApiErrorKind.network,
      );
    }

    // 401 means the session is already invalid server-side; treat as success.
    if (response.statusCode == 200 ||
        response.statusCode == 204 ||
        response.statusCode == 401) {
      return;
    }

    throw ApiException(
      'Unable to complete logout. Please try again.',
      kind: ApiErrorKind.server,
      statusCode: response.statusCode,
    );
  }

  Map<String, String> _authHeaders(String token) => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };

  Future<http.Response> _authed(
    String token,
    Future<http.Response> Function() send,
  ) async {
    if (token.trim().isEmpty) {
      throw const ApiException(
        'Authentication required',
        kind: ApiErrorKind.unauthorized,
      );
    }

    try {
      return await send().timeout(const Duration(seconds: 10));
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'Request timed out',
        kind: ApiErrorKind.timeout,
      );
    } catch (_) {
      throw const ApiException(
        'Unable to connect to the server',
        kind: ApiErrorKind.network,
      );
    }
  }

  void _ensureFriendsSuccess(http.Response response, {required Set<int> ok}) {
    if (ok.contains(response.statusCode)) {
      return;
    }

    switch (response.statusCode) {
      case 400:
        throw ApiException(
          response.body.trim().isEmpty ? 'Invalid friends request' : response.body.trim(),
          kind: ApiErrorKind.validation,
          statusCode: 400,
        );
      case 401:
        throw const ApiException(
          'Session expired or revoked',
          kind: ApiErrorKind.unauthorized,
          statusCode: 401,
        );
      case 403:
        throw ApiException(
          response.body.trim().isEmpty ? 'Not allowed' : response.body.trim(),
          kind: ApiErrorKind.validation,
          statusCode: 403,
        );
      case 404:
        throw ApiException(
          response.body.trim().isEmpty ? 'Not found' : response.body.trim(),
          kind: ApiErrorKind.server,
          statusCode: 404,
        );
      case 409:
        throw ApiException(
          response.body.trim().isEmpty ? 'Conflict' : response.body.trim(),
          kind: ApiErrorKind.validation,
          statusCode: 409,
        );
      case 429:
        throw const ApiException(
          'Too many requests. Please try again later.',
          kind: ApiErrorKind.rateLimited,
          statusCode: 429,
        );
      default:
        throw ApiException(
          'Friends request failed',
          kind: ApiErrorKind.server,
          statusCode: response.statusCode,
        );
    }
  }

  Future<void> sendFriendRequest({
    required String token,
    required String email,
  }) async {
    final response = await _authed(
      token,
      () => client.post(
        baseUri.resolve('/friends/requests'),
        headers: _authHeaders(token),
        body: jsonEncode({'email': email.trim()}),
      ),
    );
    _ensureFriendsSuccess(response, ok: {202});
  }

  Future<List<Friend>> listFriends(String token) async {
    final response = await _authed(
      token,
      () => client.get(
        baseUri.resolve('/friends'),
        headers: _authHeaders(token),
      ),
    );
    _ensureFriendsSuccess(response, ok: {200});

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['friends'] is! List) {
      throw const ApiException(
        'Invalid friends response',
        kind: ApiErrorKind.invalidResponse,
      );
    }

    return (decoded['friends'] as List)
        .whereType<Map<String, dynamic>>()
        .map(Friend.fromJson)
        .toList();
  }

  Future<int> friendCount(String token) async {
    final response = await _authed(
      token,
      () => client.get(
        baseUri.resolve('/friends/count'),
        headers: _authHeaders(token),
      ),
    );
    _ensureFriendsSuccess(response, ok: {200});

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['count'] is! int) {
      throw const ApiException(
        'Invalid friend count response',
        kind: ApiErrorKind.invalidResponse,
      );
    }
    return decoded['count'] as int;
  }

  Future<List<FriendRequest>> listIncomingFriendRequests(String token) async {
    final response = await _authed(
      token,
      () => client.get(
        baseUri.resolve('/friends/requests/incoming'),
        headers: _authHeaders(token),
      ),
    );
    _ensureFriendsSuccess(response, ok: {200});
    return _parseRequests(response.body);
  }

  Future<List<FriendRequest>> listOutgoingFriendRequests(String token) async {
    final response = await _authed(
      token,
      () => client.get(
        baseUri.resolve('/friends/requests/outgoing'),
        headers: _authHeaders(token),
      ),
    );
    _ensureFriendsSuccess(response, ok: {200});
    return _parseRequests(response.body);
  }

  List<FriendRequest> _parseRequests(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic> || decoded['requests'] is! List) {
      throw const ApiException(
        'Invalid friend requests response',
        kind: ApiErrorKind.invalidResponse,
      );
    }
    return (decoded['requests'] as List)
        .whereType<Map<String, dynamic>>()
        .map(FriendRequest.fromJson)
        .toList();
  }

  Future<void> acceptFriendRequest({
    required String token,
    required String requestId,
  }) async {
    final response = await _authed(
      token,
      () => client.post(
        baseUri.resolve('/friends/requests/$requestId/accept'),
        headers: _authHeaders(token),
      ),
    );
    _ensureFriendsSuccess(response, ok: {204});
  }

  Future<void> rejectFriendRequest({
    required String token,
    required String requestId,
  }) async {
    final response = await _authed(
      token,
      () => client.post(
        baseUri.resolve('/friends/requests/$requestId/reject'),
        headers: _authHeaders(token),
      ),
    );
    _ensureFriendsSuccess(response, ok: {204});
  }

  Future<void> removeFriend({
    required String token,
    required String userId,
  }) async {
    final response = await _authed(
      token,
      () => client.delete(
        baseUri.resolve('/friends/$userId'),
        headers: _authHeaders(token),
      ),
    );
    _ensureFriendsSuccess(response, ok: {204});
  }

  Future<void> blockUser({
    required String token,
    required String userId,
  }) async {
    final response = await _authed(
      token,
      () => client.post(
        baseUri.resolve('/friends/blocks'),
        headers: _authHeaders(token),
        body: jsonEncode({'user_id': userId}),
      ),
    );
    _ensureFriendsSuccess(response, ok: {204});
  }

  Future<void> unblockUser({
    required String token,
    required String userId,
  }) async {
    final response = await _authed(
      token,
      () => client.delete(
        baseUri.resolve('/friends/blocks/$userId'),
        headers: _authHeaders(token),
      ),
    );
    _ensureFriendsSuccess(response, ok: {204});
  }

  Future<List<BlockedUser>> listBlockedUsers(String token) async {
    final response = await _authed(
      token,
      () => client.get(
        baseUri.resolve('/friends/blocks'),
        headers: _authHeaders(token),
      ),
    );
    _ensureFriendsSuccess(response, ok: {200});

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['blocked'] is! List) {
      throw const ApiException(
        'Invalid blocked users response',
        kind: ApiErrorKind.invalidResponse,
      );
    }

    return (decoded['blocked'] as List)
        .whereType<Map<String, dynamic>>()
        .map(BlockedUser.fromJson)
        .toList();
  }

  // --- Crypto / MLS key packages ---

  Future<String> registerMlsIdentity({
    required String token,
    required List<int> publicKey,
  }) async {
    final response = await _authed(
      token,
      () => client.post(
        baseUri.resolve('/crypto/identity'),
        headers: _authHeaders(token),
        body: jsonEncode({'public_key_b64': base64Encode(publicKey)}),
      ),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      _ensureFriendsSuccess(response, ok: {200, 201});
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded['fingerprint_hex'] as String;
  }

  Future<void> uploadKeyPackages({
    required String token,
    required List<List<int>> packages,
  }) async {
    final response = await _authed(
      token,
      () => client.post(
        baseUri.resolve('/crypto/key-packages'),
        headers: _authHeaders(token),
        body: jsonEncode({
          'packages_b64': packages.map(base64Encode).toList(),
        }),
      ),
    );
    if (response.statusCode != 204) {
      throw ApiException(
        'Key package upload failed',
        kind: ApiErrorKind.server,
        statusCode: response.statusCode,
      );
    }
  }

  Future<({List<int> keyPackage, String fingerprintHex, String publicKeyB64, String deviceId})>
      claimKeyPackage({
    required String token,
    required String peerUserId,
  }) async {
    final response = await _authed(
      token,
      () => client.post(
        baseUri.resolve('/crypto/users/$peerUserId/key-packages/claim'),
        headers: _authHeaders(token),
      ),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Claim key package failed',
        kind: ApiErrorKind.server,
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return (
      keyPackage: base64Decode(decoded['key_package_b64'] as String),
      fingerprintHex: decoded['fingerprint_hex'] as String,
      publicKeyB64: decoded['public_key_b64'] as String,
      deviceId: decoded['device_id'] as String,
    );
  }

  Future<List<({String deviceId, String fingerprintHex})>> peerIdentities({
    required String token,
    required String peerUserId,
  }) async {
    final response = await _authed(
      token,
      () => client.get(
        baseUri.resolve('/crypto/users/$peerUserId/identities'),
        headers: _authHeaders(token),
      ),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Peer identities failed',
        kind: ApiErrorKind.server,
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final list = decoded['identities'] as List? ?? const [];
    return list.whereType<Map<String, dynamic>>().map((e) {
      return (
        deviceId: e['device_id'] as String,
        fingerprintHex: e['fingerprint_hex'] as String,
      );
    }).toList();
  }

  // --- Messaging envelopes ---

  Future<ConversationInfo> openConversation({
    required String token,
    required String peerUserId,
  }) async {
    final response = await _authed(
      token,
      () => client.post(
        baseUri.resolve('/conversations'),
        headers: _authHeaders(token),
        body: jsonEncode({'peer_user_id': peerUserId}),
      ),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Open conversation failed',
        kind: ApiErrorKind.server,
        statusCode: response.statusCode,
      );
    }
    return ConversationInfo.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<ConversationInfo> establishMlsGroup({
    required String token,
    required String conversationId,
    required String mlsGroupIdHex,
  }) async {
    final response = await _authed(
      token,
      () => client.put(
        baseUri.resolve('/conversations/$conversationId/mls-group'),
        headers: _authHeaders(token),
        body: jsonEncode({'mls_group_id_hex': mlsGroupIdHex}),
      ),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Establish MLS group failed',
        kind: ApiErrorKind.server,
        statusCode: response.statusCode,
      );
    }
    return ConversationInfo.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<MessageEnvelope> sendEnvelope({
    required String token,
    required String conversationId,
    required String clientMessageId,
    required List<int> ciphertext,
    required String contentType,
  }) async {
    final response = await _authed(
      token,
      () => client.post(
        baseUri.resolve('/conversations/$conversationId/envelopes'),
        headers: _authHeaders(token),
        body: jsonEncode({
          'client_message_id': clientMessageId,
          'ciphertext_b64': base64Encode(ciphertext),
          'content_type': contentType,
        }),
      ),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw ApiException(
        'Send envelope failed',
        kind: ApiErrorKind.server,
        statusCode: response.statusCode,
      );
    }
    return MessageEnvelope.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<List<MessageEnvelope>> listEnvelopes({
    required String token,
    required String conversationId,
    int limit = 50,
  }) async {
    final response = await _authed(
      token,
      () => client.get(
        baseUri.resolve(
          '/conversations/$conversationId/envelopes?limit=$limit',
        ),
        headers: _authHeaders(token),
      ),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'List envelopes failed',
        kind: ApiErrorKind.server,
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final list = decoded['envelopes'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(MessageEnvelope.fromJson)
        .toList();
  }

  Future<List<MessageEnvelope>> syncPending({
    required String token,
    int limit = 100,
  }) async {
    final response = await _authed(
      token,
      () => client.get(
        baseUri.resolve('/envelopes/pending?limit=$limit'),
        headers: _authHeaders(token),
      ),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Sync pending failed',
        kind: ApiErrorKind.server,
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final list = decoded['envelopes'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(MessageEnvelope.fromJson)
        .toList();
  }

  Future<void> acknowledgeEnvelope({
    required String token,
    required String envelopeId,
  }) async {
    final response = await _authed(
      token,
      () => client.post(
        baseUri.resolve('/envelopes/$envelopeId/ack'),
        headers: _authHeaders(token),
      ),
    );
    if (response.statusCode != 204) {
      throw ApiException(
        'Ack failed',
        kind: ApiErrorKind.server,
        statusCode: response.statusCode,
      );
    }
  }
}
