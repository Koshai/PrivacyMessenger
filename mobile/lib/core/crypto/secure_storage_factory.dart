import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Shared secure-storage defaults for Android Keystore and iOS Keychain.
///
/// Call-auth, session tokens, MLS device material, and local history keys all
/// use this factory so iOS is not left on implicit defaults while Android
/// passes [AndroidOptions] explicitly.
FlutterSecureStorage createAppSecureStorage() {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
}
