import 'package:flutter/foundation.dart';

/// Base API URL for the current target.
///
/// `APP_ENV=local` (the default) keeps the existing loopback addresses when
/// `API_BASE_URL` is unset: Android uses 10.0.2.2, and other targets use
/// 127.0.0.1. `validation` and `production` require an https URL and do not
/// fall back to loopback.
///
/// Example:
/// `flutter build apk --dart-define=APP_ENV=validation --dart-define=API_BASE_URL=https://api.example.com`
class ApiConfig {
  static const appEnv = String.fromEnvironment('APP_ENV', defaultValue: 'local');
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  static Uri get baseUri => resolve(
        appEnv: appEnv,
        apiBaseUrl: apiBaseUrl,
        isWeb: kIsWeb,
        isAndroid: defaultTargetPlatform == TargetPlatform.android,
      );

  static Uri resolve({
    required String appEnv,
    required String apiBaseUrl,
    required bool isWeb,
    required bool isAndroid,
  }) {
    final env = appEnv.trim().toLowerCase();
    if (env != 'local' && env != 'validation' && env != 'production') {
      throw StateError('APP_ENV must be local, validation, or production');
    }
    final override = apiBaseUrl.trim();
    if (override.isNotEmpty) {
      final uri = Uri.parse(override);
      if (uri.host.isEmpty) {
        throw StateError('API_BASE_URL is missing a host');
      }
      if (env != 'local' && uri.scheme != 'https') {
        throw StateError(
          'validation and production API_BASE_URL must use https',
        );
      }
      return uri;
    }
    if (env == 'validation' || env == 'production') {
      throw StateError('API_BASE_URL is required when APP_ENV is $env');
    }
    if (isWeb) {
      return Uri.parse('http://127.0.0.1:4000');
    }
    if (isAndroid) {
      return Uri.parse('http://10.0.2.2:4000');
    }
    return Uri.parse('http://127.0.0.1:4000');
  }
}
