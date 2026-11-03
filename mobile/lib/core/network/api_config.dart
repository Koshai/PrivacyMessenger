import 'package:flutter/foundation.dart';

class ApiConfig {
  static Uri get baseUri {
    if (kIsWeb) {
      return Uri.parse('http://127.0.0.1:4000');
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return Uri.parse('http://10.0.2.2:4000');

      default:
        return Uri.parse('http://127.0.0.1:4000');
    }
  }
}
