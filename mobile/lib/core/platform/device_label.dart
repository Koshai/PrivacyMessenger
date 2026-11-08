import 'package:flutter/foundation.dart';

/// Privacy-conscious device label for OTP / session registration.
///
/// Uses only the coarse [TargetPlatform] family. Never includes hardware IDs,
/// serials, advertising IDs, or user-account identifiers.
String deviceLabelForPlatform([TargetPlatform? platform]) {
  final target = platform ?? defaultTargetPlatform;
  return switch (target) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iPhone',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => 'Device',
  };
}
