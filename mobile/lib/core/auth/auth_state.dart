enum AuthStatus { initial, checking, authenticated, signedOut, unavailable }

class AuthState {
  final AuthStatus status;
  final String? userId;
  final String? deviceId;
  final String? message;

  const AuthState({
    required this.status,
    this.userId,
    this.deviceId,
    this.message,
  });
}
