enum SafetyTrustState { unverified, verified, changed }

/// Groups a fingerprint hex for readable comparison. Does not alter the value.
///
/// Output is uppercase groups of four characters separated by spaces. The
/// underlying fingerprint string used for verification and clipboard copy must
/// remain the exact original value passed into [SafetyNumberScreen].
String formatSafetyFingerprintHex(String hex) {
  final cleaned = hex.replaceAll(RegExp(r'\s+'), '');
  final buf = StringBuffer();
  for (var i = 0; i < cleaned.length; i += 4) {
    if (i > 0) buf.write(' ');
    final end = i + 4 > cleaned.length ? cleaned.length : i + 4;
    buf.write(cleaned.substring(i, end).toUpperCase());
  }
  return buf.toString();
}

/// Human-readable trust labels. Never claim automatic verification.
String safetyTrustLabel(SafetyTrustState state) {
  return switch (state) {
    SafetyTrustState.unverified => 'Not verified',
    SafetyTrustState.verified => 'Verified by you',
    SafetyTrustState.changed => 'Safety number changed',
  };
}

abstract final class SafetyNumberCopy {
  static const whatItIs =
      'A safety number is a fingerprint of this contact’s encryption keys on '
      'their device. Matching numbers help you confirm you are talking to the '
      'person you expect.';

  static const howToCompare =
      'Ask your contact to open Safety number on their device. Compare the '
      'numbers through a trusted independent channel — for example an in-person '
      'meeting, a phone call you recognize, or another app you already trust. '
      'Do not rely on this chat alone to prove their identity.';

  static const encryptionVsVerification =
      'Messages are already end-to-end encrypted. Verifying a safety number is '
      'an extra check against impersonation. Encryption works either way; '
      'verification only happens when you compare and mark it yourself.';

  static const changedWarning =
      'This contact’s safety number changed. That can mean a new device or a '
      'security problem. Compare again before trusting this contact.';
}
