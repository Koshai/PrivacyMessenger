import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openmls/openmls.dart';
import 'package:private_messenger/core/crypto/openmls/mls_device_harness.dart';

/// Device/emulator smoke: real OpenMLS native library on Android.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Alice/Bob MLS round-trip on device storage', (tester) async {
    await Openmls.init();

    final root = await Directory.systemTemp.createTemp('pm_openmls_android_');
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    final alice = await MlsDeviceHarness.create('alice', root);
    final bob = await MlsDeviceHarness.create('bob', root);
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.createGroup();
    final invite = await alice.invite(await bob.keyPackage());
    await bob.join(invite.welcome);

    final wire = await alice.sendText('android-smoke');
    expect(await bob.receiveText(wire), 'android-smoke');

    final reply = await bob.sendText('android-ack');
    expect(await alice.receiveText(reply), 'android-ack');
  });
}
