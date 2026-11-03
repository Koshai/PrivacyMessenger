class OtpChallenge {
  final String challengeId;
  final DateTime expiresAt;
  final String message;

  const OtpChallenge({
    required this.challengeId,
    required this.expiresAt,
    required this.message,
  });

  factory OtpChallenge.fromJson(Map<String, dynamic> json) {
    final challengeId = json['challenge_id'];
    final expiresAt = json['expires_at'];
    final message = json['message'];

    if (challengeId is! String ||
        challengeId.isEmpty ||
        expiresAt is! String ||
        message is! String) {
      throw const FormatException('Invalid OTP challenge response');
    }

    final parsedExpiry = DateTime.tryParse(expiresAt);

    if (parsedExpiry == null) {
      throw const FormatException('Invalid OTP expiration');
    }

    return OtpChallenge(
      challengeId: challengeId,
      expiresAt: parsedExpiry.toUtc(),
      message: message,
    );
  }

  bool get isExpired => !DateTime.now().toUtc().isBefore(expiresAt);
}
