import 'package:flutter/foundation.dart';

/// Registers third-party crypto license notices for the about/licenses UI.
void registerCryptoLicenseNotices() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['openmls'],
      'openmls Dart package and bundled OpenMLS Rust implementation — MIT License.\n'
      'See docs/licenses/openmls-3.3.0-THIRD_PARTY_NOTICES.txt for native dependency notices.\n',
    );
    yield const LicenseEntryWithLineBreaks(
      ['flutter_webrtc'],
      'flutter_webrtc 1.6.3 — MIT License.\n'
      'Bundles Google WebRTC native binaries; retain copyright notices.\n',
    );
  });
}
