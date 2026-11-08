import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/platform/device_label.dart';

void main() {
  test('labels match platform families without hardware identifiers', () {
    expect(deviceLabelForPlatform(TargetPlatform.android), 'Android');
    expect(deviceLabelForPlatform(TargetPlatform.iOS), 'iPhone');
    expect(deviceLabelForPlatform(TargetPlatform.macOS), 'Mac');
    expect(deviceLabelForPlatform(TargetPlatform.windows), 'Windows');
    expect(deviceLabelForPlatform(TargetPlatform.linux), 'Linux');
    expect(deviceLabelForPlatform(TargetPlatform.fuchsia), 'Device');
  });

  test('default uses defaultTargetPlatform', () {
    expect(
      deviceLabelForPlatform(),
      deviceLabelForPlatform(defaultTargetPlatform),
    );
  });
}
