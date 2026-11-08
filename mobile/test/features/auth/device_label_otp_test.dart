import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/platform/device_label.dart';

void main() {
  test('iOS override never reports Android device label', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    expect(deviceLabelForPlatform(), 'iPhone');
    expect(deviceLabelForPlatform(), isNot('Android'));
  });

  test('Android override reports Android', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    expect(deviceLabelForPlatform(), 'Android');
  });
}
