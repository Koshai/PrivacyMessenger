import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/calling/ice_servers.dart';
import 'package:private_messenger/features/calling/webrtc_call_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disposeMedia is safe before renderers are initialized', () async {
    final service = WebRtcCallService(
      iceServers: const IceServerConfig(
        servers: [IceServerEntry(urls: ['stun:stun.example.test:3478'])],
      ),
    );
    // First prepare path calls disposeMedia before initialize. It must not
    // throw "Call initialize before setting the stream".
    await expectLater(service.disposeMedia(), completes);
    await expectLater(service.disposeMedia(), completes);
  });
}
