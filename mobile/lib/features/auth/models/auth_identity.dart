class AuthIdentity {
  final String userId;
  final String deviceId;
  final DateTime expiresAt;

  const AuthIdentity({
    required this.userId,
    required this.deviceId,
    required this.expiresAt,
  });

  factory AuthIdentity.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    final deviceId = json['device_id'];
    final expiresAt = json['expires_at'];

    if (userId is! String ||
        userId.isEmpty ||
        deviceId is! String ||
        deviceId.isEmpty ||
        expiresAt is! String) {
      throw const FormatException('Invalid authenticated user response');
    }

    final parsedExpiry = DateTime.tryParse(expiresAt);
    if (parsedExpiry == null) {
      throw const FormatException('Invalid session expiration');
    }

    return AuthIdentity(
      userId: userId,
      deviceId: deviceId,
      expiresAt: parsedExpiry.toUtc(),
    );
  }
}
