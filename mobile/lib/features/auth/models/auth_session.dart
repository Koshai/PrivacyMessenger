class AuthSession {
  final String userId;
  final String deviceId;
  final String token;
  final DateTime expiresAt;

  const AuthSession({
    required this.userId,
    required this.deviceId,
    required this.token,
    required this.expiresAt,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    final deviceId = json['device_id'];
    final token = json['token'];
    final expiresAt = json['expires_at'];

    if (userId is! String ||
        userId.isEmpty ||
        deviceId is! String ||
        deviceId.isEmpty ||
        token is! String ||
        token.isEmpty ||
        expiresAt is! String) {
      throw const FormatException('Invalid authentication response');
    }

    final parsedExpiry = DateTime.tryParse(expiresAt);

    if (parsedExpiry == null) {
      throw const FormatException('Invalid session expiration');
    }

    return AuthSession(
      userId: userId,
      deviceId: deviceId,
      token: token,
      expiresAt: parsedExpiry.toUtc(),
    );
  }

  bool get isExpired => !DateTime.now().toUtc().isBefore(expiresAt);
}
