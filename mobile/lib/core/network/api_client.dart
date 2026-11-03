import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;

import '../../features/auth/models/otp_challenge.dart';
import '../../features/auth/models/auth_session.dart';
import '../../features/auth/models/auth_identity.dart';

class ApiException implements Exception {
  final String message;

  const ApiException(this.message);

  @override
  String toString() => 'ApiException: $message';
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
        throw ApiException('Health check failed: HTTP ${response.statusCode}');
      }

      final body = jsonDecode(response.body);

      if (body is! Map<String, dynamic>) {
        throw const ApiException('Invalid health response');
      }

      return body['status'] == 'ok';
    } on ApiException {
      rethrow;
    } catch (error) {
      throw ApiException('Unable to reach API: ${error.runtimeType}');
    }
  }

  Future<OtpChallenge> requestOtp(String email) async {
    final normalizedEmail = email.trim();

    if (normalizedEmail.isEmpty) {
      throw const ApiException('Email is required');
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
        throw const ApiException('Invalid email address');
      }

      if (response.statusCode == 429) {
        throw const ApiException('Too many requests. Please try again later.');
      }

      if (response.statusCode != 202) {
        throw const ApiException('Unable to request verification code');
      }

      final decoded = jsonDecode(response.body);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid OTP response format');
      }

      return OtpChallenge.fromJson(decoded);
    } on ApiException {
      rethrow;
    } on FormatException {
      throw const ApiException('Authentication server returned invalid data');
    } catch (_) {
      throw const ApiException(
        'Unable to connect to the authentication server',
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
      throw ApiException('Invalid verification request');
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
            throw ApiException('Authentication server returned invalid data');
          }

        case 400:
          throw ApiException('Invalid verification request');

        case 401:
          throw ApiException('Invalid or expired verification code');

        case 429:
          throw ApiException('Too many attempts. Please try again later.');

        default:
          throw ApiException('Unable to verify your code. Please try again.');
      }
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException('Verification request timed out');
    } catch (_) {
      throw ApiException('Unable to connect to authentication server');
    }
  }

  Future<AuthIdentity> getAuthenticatedUser(String token) async {
    if (token.trim().isEmpty) {
      throw ApiException('Authentication required');
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
            throw ApiException('Authentication server returned invalid data');
          }

        case 401:
          throw ApiException('Session expired or revoked');

        default:
          throw ApiException('Unable to validate session');
      }
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException('Session validation timed out');
    } catch (_) {
      throw ApiException('Unable to connect to authentication server');
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
    } catch (_) {
      throw ApiException(
        'Unable to contact the server. Please try logging out again.',
      );
    }

    if (response.statusCode == 200 ||
        response.statusCode == 204 ||
        response.statusCode == 401) {
      return;
    }

    throw ApiException('Unable to complete logout. Please try again.');
  }
}
